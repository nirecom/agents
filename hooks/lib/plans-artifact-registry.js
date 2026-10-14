"use strict";
// hooks/lib/plans-artifact-registry.js
// The one registry of what may live in WORKFLOW_PLANS_DIR (artifacts) and what
// belongs in <WORKFLOW_STATE_DIR>/<sid>.control/ (control files). Shared by the
// placement guard, bin/check-plans-artifacts and the control-dir migration.
// Each kind carries its retention class (plan / user-requested / non-plan); sweep-plans deletes by it.
// Policy: docs/architecture/claude-code/state-dirs.md.
const fs = require("fs");
const path = require("path");
const { SESSION_ID_VALID_RE, getStatePath } = require("../workflow-state/state-io/core");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

const FORMAT_TOKENS = Object.freeze([
  "outline-plan", "detail-plan", "test-review", "security-code", "security-plan", "review-security-shared",
]);
const F = `(?:${FORMAT_TOKENS.join("|")})`;
const STAGE = "(?:outline|detail|security-plan|security-code|test-review)";
const WORKER = "worker-[a-z0-9]+(?:-[a-z0-9]+)*";

const k = (kind, source, retention) => Object.freeze({ kind, re: new RegExp(`^${source}$`), retention });
// Retention classes a kind may carry; "unknown" is a classification result, never a kind's class.
const RETENTION_CLASSES = Object.freeze(["plan", "user-requested", "non-plan"]);
const N = "non-plan";

const CONTROL_KINDS = Object.freeze([
  k("review-round-state", `${F}-(?:round-number|last-round|terminal)\\.txt`, N),
  k("unresolved-concerns", `${F}-unresolved-concerns\\.json`, N),
  k("concern-ledger", `${F}-concern-ledger(?:-cycle[0-9]+|-cap-snapshot)?\\.txt`, N),
  k("concern-carrier", `${F}-concern-carrier\\.md`, N),
  k("round-delta", `${F}-round-[0-9]+-delta-[a-z0-9]+(?:-[a-z0-9]+)*\\.txt`, N),
  k("exit6-accepted", "(?:security-code|review-plan-security|review-tests)-exit6-accepted\\.txt", N),
  k("risk-signal", "(?:outline|detail)-risk-signal\\.txt", N),
  k("worker-payload", `${WORKER}\\.json`, N),
  k("worker-dispatched", `${WORKER}\\.dispatched`, N),
  k("worker-outcome", `${WORKER}\\.outcome\\.json`, N),
  k("worker-ingested", `${WORKER}\\.ingested`, N),
  k("codex-context", "codex-context\\.md", N),
  k("codex-context-built", `codex-context\\.${F}\\.built`, N),
  k("plan-log", "plan\\.jsonl", N),
  k("changed-files", "changed-files\\.txt", N),
  k("judge-signals", "(?:complexity|outline|detail|write-tests|write-code)-signals\\.txt", N),
  k("finalize-state", "finalize-state-[0-9]+\\.json", N),
  k("finalize-binding", "finalize-binding-[0-9]+\\.json", N),
  k("issue-close-outcome", "issue-close-outcome\\.json", N),
  k("session-close-gate", "session-close-gate\\.json", N),
  k("final-report-env", "final-report-env\\.json", N),
  k("supervisor-state", "supervisor-state\\.json", N),
  k("wi-checkpoint", "wi-checkpoint\\.json", N),
  k("handoff", "handoff\\.md", N),
  k("handoff-sidecar", "handoff-(?:risk|pressure|flush-mark)\\.json", N),
  k("wt-cleanup-active", "wt-cleanup-active", N),
  k("workflow-init-aborted", "workflow-init-aborted-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\\.md", N),
  k("companion-precheck", "companion-precheck\\.json", N),
  k("intent-scan-block", "intent-scan-block\\.txt", N),
  k("guard-attempt", "guard-attempt\\.tmp", N),
]);

const SHORT_LIVED = new Set(["guard-attempt"]);
// Born in the control dir only (#2544): a PLANS_DIR copy is planted, never migrated into trust.
const NEVER_IN_PLANS_DIR = new Set(["worker-outcome", "worker-ingested"]);
const MIGRATABLE_KINDS = Object.freeze(
  CONTROL_KINDS.filter((c) => !SHORT_LIVED.has(c.kind) && !NEVER_IN_PLANS_DIR.has(c.kind)),
);

const ARTIFACT_KINDS = Object.freeze([
  k("plan-artifact", "(?:intent|outline|detail|context)\\.md", "plan"),
  k("survey", "survey-[a-z0-9]+(?:-[a-z0-9]+)*\\.md", N),
  k("issue-prefill", "issue-prefill\\.md", N),
  k("test-review", "test-review\\.md", N),
  k("test-review-fallback-raw", "test-review-fallback-raw\\.md", N),
  k("concerns-log", `(?:${STAGE}-)?concerns-log\\.md`, N),
  k("codex-round-raw", `(?:${STAGE}-)?codex-round-[0-9]+-raw\\.md`, N),
  k("debug-log", `${STAGE}-debug\\.log`, N),
  k("judge-raw", "(?:complexity|outline|detail|write-tests|write-code)-judge-raw\\.txt", N),
  k("write-code-files", "write-code-files\\.txt", N),
  k("finalize-diagnostic", `${F}-finalize-diagnostic\\.txt`, N),
  k("worker-draft", `${WORKER}\\.draft\\.json`, N),
  k("notes-backup", "notes-backup", N),
  k("issue-create-dispatch", "issue-create-dispatch\\.txt", N),
  k("issue-create-survey", "issue-create-survey\\.json", N),
  k("sweep-issues", "sweep-issues-(?:survivors|decisions)\\.tsv", N),
  k("refactor-prompts-scan", "refactor-prompts-scan\\.json", N),
  k("note", "note-[a-z0-9]+(?:-[a-z0-9]+)*\\.(?:md|txt|json|tsv)", N),
  // Usage rule (only when the user explicitly asks for a separate file): docs/architecture/claude-code/state-dirs.md, Artifacts table.
  k("user-requested", "user-requested-[a-z0-9]+(?:-[a-z0-9]+)*\\.(?:md|txt|json|tsv)", "user-requested"),
  k("sweep-plans-approved-sessions", "sweep-plans-approved-sessions\\.txt", N),
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
  try { if (!plansDir) plansDir = getWorkflowPlansDir(); } catch (_) { plansDir = null; }
  for (let i = name.indexOf("-"); i > 0; i = name.indexOf("-", i + 1)) {
    const prefix = name.slice(0, i);
    if (!SESSION_ID_VALID_RE.test(prefix)) continue;
    // Each candidate prefix is its own sid, so it routes to its own state dir (#2511).
    const workflowDir = c.workflowDir || path.dirname(getStatePath(prefix));
    if (sessionEvidence(prefix, plansDir || workflowDir, workflowDir)) return "unregistered";
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
  "user-requested": (p) => `user-requested-${p.topic}.${p.ext || "md"}`,
});

function retentionOfKind(kind) {
  const entry = [...CONTROL_KINDS, ...ARTIFACT_KINDS].find((e) => e.kind === kind);
  return entry ? entry.retention : undefined;
}

// Classified only through parsePlansEntry, so the ambiguity rule stays in one place;
// a sid-less name or a sid other than expectedSid is "unknown".
function retentionClassOf(name, expectedSid) {
  const parsed = parsePlansEntry(name);
  if (!parsed || parsed.verdict === "ambiguous") return "unknown";
  if (parsed.sid !== expectedSid) return "unknown";
  const retention = retentionOfKind(parsed.kind);
  return RETENTION_CLASSES.includes(retention) ? retention : "unknown";
}

function retentionCoverageErrors(table) {
  const controlKinds = (table && table.controlKinds) || CONTROL_KINDS;
  const artifactKinds = (table && table.artifactKinds) || ARTIFACT_KINDS;
  return [...controlKinds, ...artifactKinds]
    .filter((e) => !RETENTION_CLASSES.includes(e.retention))
    .map((e) => `${e.kind}: ${e.retention}`);
}

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

// The plan-artifact kinds plan-sync publishes: every plan-artifact name except
// context.md, which carries session-local working notes rather than a plan.
const SYNCED_PLAN_ARTIFACT_KINDS = Object.freeze(["intent", "outline", "detail"]);

function planArtifactNames() {
  return SYNCED_PLAN_ARTIFACT_KINDS.map((kind) => ARTIFACT_NAMES[kind]());
}

module.exports = {
  SYNCED_PLAN_ARTIFACT_KINDS,
  planArtifactNames,
  FORMAT_TOKENS,
  CONTROL_KINDS,
  MIGRATABLE_KINDS,
  ARTIFACT_KINDS,
  SOURCE_LINT_EXCEPTIONS,
  RETENTION_CLASSES,
  retentionClassOf,
  retentionCoverageErrors,
  parsePlansEntry,
  classifyPlansEntry,
  legacyBasename,
  getPlansArtifactPath,
};
