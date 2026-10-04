"use strict";
// hooks/lib/plans-artifact-registry.js
// The one registry of what may live in WORKFLOW_PLANS_DIR (artifacts) and what
// belongs in <WORKFLOW_STATE_DIR>/<sid>.control/ (control files). Shared by the
// placement guard, bin/check-plans-artifacts and the control-dir migration.
// Policy: docs/architecture/claude-code/state-dirs.md.
const fs = require("fs");
const path = require("path");
const { SESSION_ID_VALID_RE, getWorkflowDir } = require("../workflow-state/state-io/core");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

const FORMAT_TOKENS = Object.freeze([
  "outline-plan", "detail-plan", "test-review", "security-code", "security-plan", "review-security-shared",
]);
const F = `(?:${FORMAT_TOKENS.join("|")})`;
const STAGE = "(?:outline|detail|security-plan|security-code|test-review)";
const WORKER = "worker-[a-z0-9]+(?:-[a-z0-9]+)*";

const k = (kind, source) => Object.freeze({ kind, re: new RegExp(`^${source}$`) });

const CONTROL_KINDS = Object.freeze([
  k("review-round-state", `${F}-(?:round-number|last-round|terminal)\\.txt`),
  k("unresolved-concerns", `${F}-unresolved-concerns\\.json`),
  k("concern-ledger", `${F}-concern-ledger(?:-cycle[0-9]+|-cap-snapshot)?\\.txt`),
  k("concern-carrier", `${F}-concern-carrier\\.md`),
  k("round-delta", `${F}-round-[0-9]+-delta-[a-z0-9]+(?:-[a-z0-9]+)*\\.txt`),
  k("exit6-accepted", "(?:security-code|review-plan-security|review-tests)-exit6-accepted\\.txt"),
  k("risk-signal", "(?:outline|detail)-risk-signal\\.txt"),
  k("worker-payload", `${WORKER}\\.json`),
  k("worker-dispatched", `${WORKER}\\.dispatched`),
  k("codex-context", "codex-context\\.md"),
  k("codex-context-built", `codex-context\\.${F}\\.built`),
  k("plan-log", "plan\\.jsonl"),
  k("changed-files", "changed-files\\.txt"),
  k("judge-signals", "(?:complexity|outline|detail|write-tests|write-code)-signals\\.txt"),
  k("finalize-state", "finalize-state-[0-9]+\\.json"),
  k("finalize-binding", "finalize-binding-[0-9]+\\.json"),
  k("issue-close-outcome", "issue-close-outcome\\.json"),
  k("session-close-gate", "session-close-gate\\.json"),
  k("final-report-env", "final-report-env\\.json"),
  k("supervisor-state", "supervisor-state\\.json"),
  k("wi-checkpoint", "wi-checkpoint\\.json"),
  k("handoff", "handoff\\.md"),
  k("handoff-sidecar", "handoff-(?:risk|pressure|flush-mark)\\.json"),
  k("wt-cleanup-active", "wt-cleanup-active"),
  k("workflow-init-aborted", "workflow-init-aborted-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\\.md"),
  k("companion-precheck", "companion-precheck\\.json"),
  k("intent-scan-block", "intent-scan-block\\.txt"),
  k("guard-attempt", "guard-attempt\\.tmp"),
]);

const SHORT_LIVED = new Set(["guard-attempt"]);
const MIGRATABLE_KINDS = Object.freeze(CONTROL_KINDS.filter((c) => !SHORT_LIVED.has(c.kind)));

const ARTIFACT_KINDS = Object.freeze([
  k("plan-artifact", "(?:intent|outline|detail|context)\\.md"),
  k("survey", "survey-[a-z0-9]+(?:-[a-z0-9]+)*\\.md"),
  k("issue-prefill", "issue-prefill\\.md"),
  k("test-review", "test-review\\.md"),
  k("test-review-fallback-raw", "test-review-fallback-raw\\.md"),
  k("concerns-log", `(?:${STAGE}-)?concerns-log\\.md`),
  k("codex-round-raw", `(?:${STAGE}-)?codex-round-[0-9]+-raw\\.md`),
  k("debug-log", `${STAGE}-debug\\.log`),
  k("judge-raw", "(?:complexity|outline|detail|write-tests|write-code)-judge-raw\\.txt"),
  k("finalize-diagnostic", `${F}-finalize-diagnostic\\.txt`),
  k("worker-draft", `${WORKER}\\.draft\\.json`),
  k("finalize-worker-log", "finalize-worker-[A-Za-z0-9._]+(?:-[A-Za-z0-9._]+)*\\.log"),
  k("session-close-worker-log", "session-close-worker\\.log"),
  k("notes-backup", "notes-backup"),
  k("issue-create-dispatch", "issue-create-dispatch\\.txt"),
  k("issue-create-survey", "issue-create-survey\\.json"),
  k("sweep-issues", "sweep-issues-(?:survivors|decisions)\\.tsv"),
  k("refactor-prompts-scan", "refactor-prompts-scan\\.json"),
  k("note", "note-[a-z0-9]+(?:-[a-z0-9]+)*\\.(?:md|txt|json|tsv)"),
]);

// Unregistered names are never allowed a silent pass; each exception needs a reason.
const SOURCE_LINT_EXCEPTIONS = Object.freeze([
  Object.freeze({
    file: "bin/review-plan-codex",
    pattern: /\{EFF_SESSION_ID\}-plan\.jsonl$/,
    reason: "caller-supplied --log-dir outside the session control dir (standalone runs); the control-dir branch uses plan.jsonl",
  }),
  Object.freeze({
    file: "hooks/lib/supervisor-codex-input/assemble.js",
    pattern: /\$\{wsid\}-\$\{k\}\.md$/,
    reason: "${k} iterates the registered plan artifacts intent/outline/detail only; the template is statically unresolvable",
  }),
]);

const reOf = (entry) => (entry instanceof RegExp ? entry : entry.re);
const kindOf = (entry) => (entry instanceof RegExp ? String(entry) : entry.kind);

function parsePlansEntry(name, table) {
  if (typeof name !== "string" || name.length === 0) return null;
  const controlKinds = (table && table.controlKinds) || CONTROL_KINDS;
  const artifactKinds = (table && table.artifactKinds) || ARTIFACT_KINDS;
  const candidates = [];
  for (let i = name.indexOf("-"); i > 0; i = name.indexOf("-", i + 1)) {
    const sid = name.slice(0, i);
    const remainder = name.slice(i + 1);
    if (!SESSION_ID_VALID_RE.test(sid) || remainder.length === 0) continue;
    for (const [verdict, list] of [["control", controlKinds], ["artifact", artifactKinds]]) {
      for (const entry of list) {
        if (reOf(entry).test(remainder)) candidates.push({ sid, name: remainder, entry, verdict });
      }
    }
  }
  if (candidates.length === 0) return null;
  const distinct = new Set(candidates.map((c) => c.entry));
  // A generic artifact word (context.md) can end a control name (codex-context.md):
  // a single control reading at the shortest sid outranks artifact readings at longer sids.
  const first = candidates[0];
  const rest = candidates.filter((c) => c.sid !== first.sid);
  const atFirst = new Set(candidates.filter((c) => c.sid === first.sid).map((c) => c.entry));
  if (distinct.size > 1 && first.verdict === "control" && atFirst.size === 1
      && rest.length > 0 && rest.every((c) => c.verdict === "artifact")) {
    return { sid: first.sid, name: first.name, kind: kindOf(first.entry), verdict: first.verdict };
  }
  if (distinct.size > 1) {
    return { verdict: "ambiguous", candidates: candidates.map((c) => ({ sid: c.sid, kind: kindOf(c.entry) })) };
  }
  return { sid: first.sid, name: first.name, kind: kindOf(first.entry), verdict: first.verdict };
}

function sessionEvidence(prefix, plansDir, workflowDir) {
  const probes = [
    path.join(plansDir, `${prefix}-context.md`),
    path.join(plansDir, `${prefix}-intent.md`),
    path.join(workflowDir, `${prefix}.json`),
  ];
  return probes.some((p) => { try { fs.statSync(p); return true; } catch (_) { return false; } });
}

function classifyPlansEntry(name, ctx) {
  const c = ctx || {};
  const parsed = parsePlansEntry(name);
  if (parsed) return parsed.verdict;
  for (const own of [c.sid, c.wsid]) {
    if (typeof own === "string" && own.length > 0 && name.startsWith(`${own}-`)) return "unregistered";
  }
  let plansDir = c.plansDir;
  let workflowDir = c.workflowDir;
  try { if (!plansDir) plansDir = getWorkflowPlansDir(); } catch (_) { plansDir = null; }
  if (!workflowDir) workflowDir = getWorkflowDir();
  for (let i = name.indexOf("-"); i > 0; i = name.indexOf("-", i + 1)) {
    const prefix = name.slice(0, i);
    if (!SESSION_ID_VALID_RE.test(prefix)) continue;
    if (plansDir && sessionEvidence(prefix, plansDir, workflowDir)) return "unregistered";
    if (!plansDir && sessionEvidence(prefix, workflowDir, workflowDir)) return "unregistered";
  }
  return "no-sid";
}

function legacyBasename(sid, name) {
  return `${sid}-${name}`;
}

const ARTIFACT_NAMES = Object.freeze({
  intent: () => "intent.md",
  outline: () => "outline.md",
  detail: () => "detail.md",
  context: () => "context.md",
  "issue-prefill": () => "issue-prefill.md",
  "test-review": () => "test-review.md",
  "concerns-log": (p) => (p && p.stage ? `${p.stage}-concerns-log.md` : "concerns-log.md"),
  "codex-round-raw": (p) => `${p && p.stage ? `${p.stage}-` : ""}codex-round-${Number(p && p.round)}-raw.md`,
  "worker-draft": (p) => `worker-${p.worker}${p.seq !== undefined ? `-${p.seq}` : ""}.draft.json`,
  survey: (p) => `survey-${p.name}.md`,
  note: (p) => `note-${p.topic}.${p.ext || "md"}`,
});

function getPlansArtifactPath(sid, kind, opts) {
  const build = Object.prototype.hasOwnProperty.call(ARTIFACT_NAMES, kind) ? ARTIFACT_NAMES[kind] : null;
  if (!build) throw new Error(`plans-artifact-registry: unregistered artifact kind: ${kind}`);
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) {
    throw new Error(`plans-artifact-registry: invalid session id: ${JSON.stringify(sid)}`);
  }
  const o = opts || {};
  const name = build(o);
  const parsed = parsePlansEntry(legacyBasename(sid, name));
  if (!parsed || parsed.verdict !== "artifact") {
    throw new Error(`plans-artifact-registry: ${name} does not parse as an artifact`);
  }
  return path.join(o.plansDir || getWorkflowPlansDir(), legacyBasename(sid, name));
}

module.exports = {
  FORMAT_TOKENS,
  CONTROL_KINDS,
  MIGRATABLE_KINDS,
  ARTIFACT_KINDS,
  SOURCE_LINT_EXCEPTIONS,
  parsePlansEntry,
  classifyPlansEntry,
  legacyBasename,
  getPlansArtifactPath,
};
