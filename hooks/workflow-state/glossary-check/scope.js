"use strict";
// hooks/workflow-state/glossary-check/scope.js — the single reader of the glossary-check inputs
// (#2529 invariant I-FP): artifact, combined glossary, intent rows and rules. The scan, the grant
// handlers and the commit gate read loadStageInputs' result and never re-read an input.
// Artifact rules R-A / R-S live in scope/artifact.js; inputs 2 and 3 in scope/sources.js.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { toWindowsPath } = require("../../lib/branch-diff");
const { DOCS_ONLY_ALLOWLIST } = require("../../workflow-gate/staged-evidence");
const { sha256, artifactRA, artifactRS } = require("./scope/artifact");
const { combinedGlossary, intentRowsOf } = require("./scope/sources");

const STAGE_STEP = Object.freeze({
  intent: "clarify_intent", outline: "outline", detail: "detail",
  tests: "review_tests", code: "review_security", docs: "review_docs",
});
const RA_STAGES = Object.freeze(["intent", "outline", "detail"]);
const RS_STAGES = Object.freeze(["tests", "code", "docs"]);
const STAGE_LEDGER_FORMAT = Object.freeze({
  outline: "outline-plan", detail: "detail-plan", tests: "test-review", code: "review-security-shared",
});

const REPO_ROOT = path.join(__dirname, "..", "..", "..");
const RULE_MODULES = Object.freeze(["bin/lib/glossary-drift.js", "hooks/lib/glossary-term.js",
  "hooks/lib/comment-block-scan.js", "hooks/lib/markdown-fence.js", "bin/lib/glossary-provenance.js"].map((rel) => path.join(REPO_ROOT, rel)));

function stageOfStep(step) {
  return Object.keys(STAGE_STEP).find((s) => STAGE_STEP[s] === step) || null;
}

function stageOfLedgerFormat(format) {
  return Object.keys(STAGE_LEDGER_FORMAT).find((s) => STAGE_LEDGER_FORMAT[s] === format) || null;
}

function classifyStageFile(p) {
  const rel = String(p).replace(/\\/g, "/");
  if (rel.startsWith("tests/") || rel.startsWith("test/")) return "tests";
  return DOCS_ONLY_ALLOWLIST.test(rel) ? "docs" : "code";
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

// loadStageInputs(sid, stage, opts) -> { ok: true, stage, repoDir, artifact, glossary, intentRows,
// rules } | { ok: false, error, detail }. Each input is read exactly once.
function loadStageInputs(sid, stage, opts) {
  const o = opts || {};
  if (!Object.prototype.hasOwnProperty.call(STAGE_STEP, stage)) return { ok: false, error: "unknown-stage", detail: stage };
  const repoDir = resolveRepoDir(sid, o);
  if (!repoDir) return { ok: false, error: "worktree-unresolved", detail: null };
  const art = RA_STAGES.includes(stage) ? artifactRA(sid, STAGE_STEP[stage]) : artifactRS(repoDir, stage, classifyStageFile);
  if (!art.ok) return art;
  const glossary = combinedGlossary({ repoDir });
  if (!glossary.ok) return { ok: false, error: glossary.error, detail: glossary.detail };
  const intentRows = intentRowsOf(sid, stage === "intent" ? art.rangeText : undefined);
  if (!intentRows.ok) return { ok: false, error: intentRows.error, detail: intentRows.detail };
  const rules = rulesVersion(o);
  if (!rules.digest) return { ok: false, error: rules.error, detail: rules.detail };
  return {
    ok: true, stage, repoDir, artifact: art.artifact,
    glossary: { files: glossary.files, terms: glossary.terms, digest: glossary.digest, legacy: glossary.legacy },
    intentRows: { rows: intentRows.rows, digest: intentRows.digest },
    rules,
  };
}

const fingerprintOfDigests = (d) => sha256(JSON.stringify(d));

// fingerprintOf(inputs) -> { ok, fingerprint, inputs } from a loadStageInputs result.
function fingerprintOf(loaded) {
  if (!loaded || !loaded.ok) return { ok: false, error: loaded ? loaded.error : "no-inputs", detail: loaded && loaded.detail };
  const inputs = {
    artifact: loaded.artifact.digest, glossary: loaded.glossary.digest,
    intent_rows: loaded.intentRows.digest, rules: loaded.rules.digest,
  };
  return { ok: true, fingerprint: fingerprintOfDigests(inputs), inputs };
}

function stageFingerprint(sid, stage, opts) {
  return fingerprintOf(loadStageInputs(sid, stage, opts));
}

// provenanceFingerprint({ ops, approvalSha }) -> { fingerprint, inputs: { ops, intent_rows, rules } }.
function provenanceFingerprint(args) {
  const a = args || {};
  const inputs = { ops: a.ops || null, intent_rows: a.approvalSha || null, rules: rulesVersion(a).digest };
  return { fingerprint: fingerprintOfDigests(inputs), inputs };
}

module.exports = {
  STAGE_STEP, RA_STAGES, RS_STAGES, STAGE_LEDGER_FORMAT, RULE_MODULES,
  stageOfStep, stageOfLedgerFormat, classifyStageFile, rulesVersion, combinedGlossary,
  loadStageInputs, fingerprintOf, stageFingerprint, provenanceFingerprint,
};
