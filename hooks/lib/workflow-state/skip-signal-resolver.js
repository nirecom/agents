"use strict";
// Skip-signal resolver (#485 + #1286): advisory predicate (isTrivial) and
// recorded-verdict judgment (recordSkipJudgment / hasValidSkipJudgment).
//
// isTrivial: WEAK SUPPLEMENTARY hint only (demoted from sole gate by #1286).
//   Fails-open to FALSE (uncertain ⇒ run full workflow).
//   Mirrors the read-only / fail-open shape of evidence-resolver.js.
//
// Recorded-verdict API (#1286):
//   skip_judgment schema — stored at state.steps[targetStep].skip_judgment:
//     recorded_at:        ISO timestamp string (new Date().toISOString())
//     judgment_source:    string; only "orchestrator" is a valid authoritative value
//     conditions:         gate-specific boolean object:
//                           outline: { so_c1, so_c2 }  (so = skip-outline)
//                           detail:  { sd_c1, sd_c2, sd_c3 }  (sd = skip-detail)
//     all_conditions_met: boolean = AND of all condition booleans in conditions
//
// recordSkipJudgment: records judgment without changing step status (fail-open/silent).
// readSkipJudgment:   returns skip_judgment object or null (fail-open).
// hasValidSkipJudgment: returns true iff source=orchestrator AND all_conditions_met=true.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("./state-io");

// ---- isTrivial keyword sets (module-level frozen, referenced by tests + describe) ----

// Mechanical-transformation keywords: at least one must be present.
const MECHANICAL_RE = Object.freeze([
  /\brename\b/,
  /\bfix typo\b/,
  /\btypo\b/,
  /\bremove unused\b/,
  /\bextract\b/,
  /\bmove\b/,
]);

// Broad-change keywords: none may be present.
const BROAD_RE = Object.freeze([
  /\bacross the codebase\b/,
  /\bredesign\b/,
  /\bnew interface\b/,
  /\bevery\b/,
  /\bentire\b/,
]);

// New-API-surface declarations: none may be present.
const NEW_API_RE = Object.freeze([
  /\bnew api\b/,
  /\bnew endpoint\b/,
  /\bpublic api\b/,
  /\bnew interface\b/,
  /\bnew command\b/,
  /\bnew sentinel\b/,
]);

// isTrivial(sessionId, plansDir): planning-stage predicate. Reads intent.md TEXT
// only (no staged files exist at planning time). fail-open direction = FALSE.
function isTrivial(sessionId, plansDir) {
  try {
    if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return false;
    const dir = (typeof plansDir === "string" && plansDir.length)
      ? plansDir
      : getWorkflowPlansDir();
    const intentPath = path.join(dir, sessionId + "-intent.md");
    if (!fs.existsSync(intentPath)) return false;
    const text = fs.readFileSync(intentPath, "utf8").toLowerCase();

    const hasMechanical = MECHANICAL_RE.some((re) => re.test(text));
    if (!hasMechanical) return false;
    if (BROAD_RE.some((re) => re.test(text))) return false;
    if (NEW_API_RE.some((re) => re.test(text))) return false;
    return true;
  } catch (e) {
    // fail-open: uncertain ⇒ not trivial ⇒ full workflow.
    return false;
  }
}

// ---- Per-target condition schemas (#1300 hardening #2) ---------------------

const CONDITION_SCHEMAS = Object.freeze({
  outline: Object.freeze(["so_c1", "so_c2"]),
  detail: Object.freeze(["sd_c1", "sd_c2", "sd_c3"]),
});

function isRecordedVerdictValid(sj, targetStep) {
  try {
    if (!sj || typeof sj !== "object" || Array.isArray(sj)) return false;
    if (sj.judgment_source !== "orchestrator") return false;
    if (sj.all_conditions_met !== true) return false;
    const expectedKeys = CONDITION_SCHEMAS[targetStep];
    if (!expectedKeys) return false;
    const cond = sj.conditions;
    if (!cond || typeof cond !== "object" || Array.isArray(cond)) return false;
    const actualKeys = Object.keys(cond);
    if (actualKeys.length !== expectedKeys.length) return false;
    for (const k of expectedKeys) {
      if (cond[k] !== true) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

// ---- Recorded-verdict API (#1286) -----------------------------------------

// recordSkipJudgment(sessionId, targetStep, conditions, source):
// Attaches a skip_judgment record to state.steps[targetStep] WITHOUT changing
// the step's status. Fail-open: any error → silent return.
function recordSkipJudgment(sessionId, targetStep, conditions, source) {
  try {
    if (targetStep !== "outline" && targetStep !== "detail") return;
    const { readState, markStep } = require("./state-io");
    const state = readState(sessionId);
    const currentStatus = (state && state.steps && state.steps[targetStep] && state.steps[targetStep].status) || "pending";
    const condVals = Object.values(conditions || {});
    const all_conditions_met = condVals.length > 0 && condVals.every((v) => v === true);
    const skip_judgment = {
      recorded_at: new Date().toISOString(),
      judgment_source: source,
      conditions: conditions || {},
      all_conditions_met,
    };
    markStep(sessionId, targetStep, currentStatus, { skip_judgment });
  } catch (_) {
    // fail-open: silent
  }
}

// readSkipJudgment(sessionId, targetStep):
// Returns state.steps[targetStep].skip_judgment if present and a valid object
// with all required fields; else null. Fail-open: any exception → null.
function readSkipJudgment(sessionId, targetStep) {
  try {
    const { readState } = require("./state-io");
    const state = readState(sessionId);
    if (!state || !state.steps || !state.steps[targetStep]) return null;
    const sj = state.steps[targetStep].skip_judgment;
    if (!sj || typeof sj !== "object" || Array.isArray(sj)) return null;
    // Require the essential fields to be present (partial objects → null).
    if (!("judgment_source" in sj) || !("all_conditions_met" in sj) || !("conditions" in sj) || !("recorded_at" in sj)) return null;
    return sj;
  } catch (_) {
    return null;
  }
}

// hasValidSkipJudgment(sessionId, targetStep):
// Returns true iff readSkipJudgment returns a non-null object AND
// judgment_source === "orchestrator" AND all_conditions_met === true AND
// conditions matches the per-target schema exactly (hardening #2, #1300).
// Never throws (fail to false).
function hasValidSkipJudgment(sessionId, targetStep) {
  try {
    const sj = readSkipJudgment(sessionId, targetStep);
    if (!sj) return false;
    // Artifact path mapping (intent.md scope):
    //   outline → <PLANS_DIR>/<sid>-intent.md
    //   detail  → <PLANS_DIR>/<sid>-outline.md
    const artifactSuffix = targetStep === "detail" ? "-outline.md" : "-intent.md";
    const artifactPath = path.join(getWorkflowPlansDir(), sessionId + artifactSuffix);
    let artifactMtimeMs;
    try {
      artifactMtimeMs = fs.statSync(artifactPath).mtimeMs;
    } catch (_) {
      // ENOENT or permission error → treat as stale → false
      return false;
    }
    const recordedAtMs = new Date(sj.recorded_at).getTime();
    if (isNaN(recordedAtMs)) return false;
    // Floor to ms precision to match toISOString() truncation on sub-ms filesystems (NTFS).
    if (Math.floor(artifactMtimeMs) > recordedAtMs) return false;
    return isRecordedVerdictValid(sj, targetStep);
  } catch (_) {
    return false;
  }
}

// ---- Complexity-evaluation API (#1350) ------------------------------------

// readComplexityEvaluation(sessionId):
// Returns state.complexity_evaluation if present and a valid object with all
// required fields (verdict:string, recorded_at:string, signals:Array); else null.
// Fail-open: any exception → null.
function readComplexityEvaluation(sessionId) {
  try {
    const { readState } = require("./state-io");
    const state = readState(sessionId);
    if (!state) return null;
    const ce = state.complexity_evaluation;
    // signals MUST be an array — consumers call ce.signals.join(); a non-array
    // would throw a TypeError downstream, so reject it here.
    if (!ce || typeof ce !== "object" || typeof ce.verdict !== "string" || typeof ce.recorded_at !== "string" || !Array.isArray(ce.signals)) return null;
    return ce;
  } catch (_) {
    return null;
  }
}

// hasComplexityEvaluation(sessionId):
// Returns true iff a valid evaluation exists with verdict opus|sonnet.
// Never throws (fail-to-false). No mtime/staleness check (unlike
// hasValidSkipJudgment): complexity is a session-lifetime fact, not tied to
// artifact freshness — a recorded verdict stays valid for the whole session.
function hasComplexityEvaluation(sessionId) {
  const ce = readComplexityEvaluation(sessionId);
  if (!ce) return false;
  return ce.verdict === "opus" || ce.verdict === "sonnet";
}

// describeSkipSignal(predicate): human-readable description of what a predicate
// checks (mirrors evidence-resolver.js describeEvidence, but returns a single
// joined string). For diagnostics/tests.
function describeSkipSignal(predicate) {
  if (predicate === "isTrivial") {
    return [
      "<PLANS_DIR>/<sessionId>-intent.md contains a mechanical-transformation keyword " +
        "(rename / fix typo / typo / remove unused / extract / move)",
      "AND contains no broad-change keyword (across the codebase / redesign / new interface / every / entire)",
      "AND contains no new-API-surface declaration (new api / new endpoint / public api / new interface / new command / new sentinel)",
      "fail-open direction = false (uncertain ⇒ not trivial ⇒ full workflow)",
    ].join("; ");
  }
  return "";
}

module.exports = {
  isTrivial,
  describeSkipSignal,
  MECHANICAL_RE,
  BROAD_RE,
  NEW_API_RE,
  CONDITION_SCHEMAS,
  isRecordedVerdictValid,
  recordSkipJudgment,
  readSkipJudgment,
  hasValidSkipJudgment,
  readComplexityEvaluation,
  hasComplexityEvaluation,
};
