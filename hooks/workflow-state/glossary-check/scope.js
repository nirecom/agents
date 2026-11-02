"use strict";
// hooks/workflow-state/glossary-check/scope.js — the single reader of the glossary-check inputs
// (#2529 invariant I-FP): artifact, combined glossary, intent rows and rules. The scan, the grant
// handlers and the commit gate read loadStepInputs' result and never re-read an input.
// Artifact rules R-A / R-S live in scope/artifact.js; inputs 2 and 3 in scope/sources.js.
// Every key here is a workflow step (#2820).

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { toWindowsPath } = require("../../lib/branch-diff");
const { DOCS_ONLY_ALLOWLIST } = require("../../workflow-gate/staged-evidence");
const { sha256, artifactRA, artifactRS } = require("./scope/artifact");
const { combinedGlossary, intentRowsOf } = require("./scope/sources");

// R-A: the plan steps (their plan artifact); R-S: the review steps (the staged files).
const RA_STEPS = Object.freeze(["clarify_intent", "outline", "detail"]);
const RS_STEPS = Object.freeze(["review_tests", "review_security", "review_docs"]);
const GLOSSARY_STEPS = Object.freeze(RA_STEPS.concat(RS_STEPS));
const LEDGER_FORMAT_OF_STEP = Object.freeze({
  outline: "outline-plan", detail: "detail-plan", review_tests: "test-review", review_security: "review-security-shared",
});

const REPO_ROOT = path.join(__dirname, "..", "..", "..");
const RULE_MODULES = Object.freeze(["bin/lib/glossary-drift.js", "hooks/lib/glossary-term.js",
  "hooks/lib/comment-block-scan.js", "hooks/lib/markdown-fence.js", "bin/lib/glossary-provenance.js",
  "bin/lib/glossary-drift/extract.js", "bin/lib/glossary-drift/terms.js", "bin/lib/glossary-drift/context.js",
  "bin/lib/glossary-drift/match.js", "bin/lib/glossary-drift/scan.js",
  "hooks/workflow-state/glossary-check/scope/changed-lines.js"].map((rel) => path.join(REPO_ROOT, rel)));

const isGlossaryStep = (step) => GLOSSARY_STEPS.includes(step);

function stepOfLedgerFormat(format) {
  return Object.keys(LEDGER_FORMAT_OF_STEP).find((s) => LEDGER_FORMAT_OF_STEP[s] === format) || null;
}

// reviewStepOfFile(path) -> the R-S step whose scan covers a staged path.
function reviewStepOfFile(p) {
  const rel = String(p).replace(/\\/g, "/");
  if (rel.startsWith("tests/") || rel.startsWith("test/")) return "review_tests";
  return DOCS_ONLY_ALLOWLIST.test(rel) ? "review_docs" : "review_security";
}

// rulesVersion(opts) -> { digest }: sha256 over the path-ordered sha256 of each rule module.
// opts.ruleModules replaces the module paths (test seam).
function rulesVersion(opts) {
  const paths = ((opts && opts.ruleModules) || RULE_MODULES).slice().sort();
  try {
    const shas = paths.map((p) => sha256(fs.readFileSync(toWindowsPath(p))));
    return { digest: sha256(shas.join("")) };
  } catch (e) {
    return { digest: null, error: "rules-unreadable", detail: e && e.message ? e.message : String(e) };
  }
}

function gitRootOfCwd() {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd: process.cwd(), encoding: "utf8", timeout: 5000 });
  return r.error || r.status !== 0 ? null : r.stdout.trim() || null;
}

// The worktree: opts.repoDir, then the session's linked worktree, then the cwd's git root.
function resolveRepoDir(sid, opts) {
  if (opts && opts.repoDir) return toWindowsPath(opts.repoDir);
  const { resolveSessionWorktreePath } = require("../resolve-worktree-path");
  const wt = resolveSessionWorktreePath(sid);
  if (wt) return toWindowsPath(wt);
  const root = gitRootOfCwd();
  return root ? toWindowsPath(root) : null;
}

// loadStepInputs(sid, step, opts) -> { ok: true, step, repoDir, artifact, glossary, intentRows,
// rules } | { ok: false, error, detail }. Each input is read exactly once.
function loadStepInputs(sid, step, opts) {
  const o = opts || {};
  if (!isGlossaryStep(step)) return { ok: false, error: "unknown-step", detail: step };
  const repoDir = resolveRepoDir(sid, o);
  if (!repoDir) return { ok: false, error: "worktree-unresolved", detail: null };
  const art = RA_STEPS.includes(step) ? artifactRA(sid, step) : artifactRS(repoDir, step, reviewStepOfFile);
  if (!art.ok) return art;
  const glossary = combinedGlossary({ repoDir });
  if (!glossary.ok) return { ok: false, error: glossary.error, detail: glossary.detail };
  const intentRows = intentRowsOf(sid, step === "clarify_intent" ? art.rangeText : undefined);
  if (!intentRows.ok) return { ok: false, error: intentRows.error, detail: intentRows.detail };
  const rules = rulesVersion(o);
  if (!rules.digest) return { ok: false, error: rules.error, detail: rules.detail };
  return {
    ok: true, step, repoDir, artifact: art.artifact,
    glossary: { files: glossary.files, terms: glossary.terms, digest: glossary.digest, legacy: glossary.legacy },
    intentRows: { rows: intentRows.rows, digest: intentRows.digest },
    rules,
  };
}

const fingerprintOfDigests = (d) => sha256(JSON.stringify(d));

// fingerprintOf(inputs) -> { ok, fingerprint, inputs } from a loadStepInputs result.
function fingerprintOf(loaded) {
  if (!loaded || !loaded.ok) return { ok: false, error: loaded ? loaded.error : "no-inputs", detail: loaded && loaded.detail };
  const inputs = {
    artifact: loaded.artifact.digest, glossary: loaded.glossary.digest,
    intent_rows: loaded.intentRows.digest, rules: loaded.rules.digest,
  };
  return { ok: true, fingerprint: fingerprintOfDigests(inputs), inputs };
}

function stepFingerprint(sid, step, opts) {
  return fingerprintOf(loadStepInputs(sid, step, opts));
}

// provenanceFingerprint({ ops, approvalSha }) -> { fingerprint, inputs: { ops, intent_rows, rules } }.
function provenanceFingerprint(args) {
  const a = args || {};
  const inputs = { ops: a.ops || null, intent_rows: a.approvalSha || null, rules: rulesVersion(a).digest };
  return { fingerprint: fingerprintOfDigests(inputs), inputs };
}

module.exports = {
  GLOSSARY_STEPS, RA_STEPS, RS_STEPS, LEDGER_FORMAT_OF_STEP, RULE_MODULES,
  stepOfLedgerFormat, reviewStepOfFile, rulesVersion, combinedGlossary,
  loadStepInputs, fingerprintOf, stepFingerprint, provenanceFingerprint,
};
