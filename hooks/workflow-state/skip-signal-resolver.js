"use strict";
// Skip-signal resolver (#485 + #1286): advisory predicate (isTrivial) and
// recorded-verdict judgment (recordSkipJudgment / hasValidSkipJudgment). The
// complexity-evaluation read side lives in skip-signal-resolver/complexity.js
// and is re-exported from here unchanged (#2099).
//
// isTrivial: WEAK SUPPLEMENTARY hint only (demoted from sole gate by #1286).
// Fails open to FALSE (uncertain ⇒ full workflow); mirrors evidence-resolver.js.
// skip_judgment schema — state.steps[targetStep].skip_judgment: recorded_at (ISO
// string), judgment_source ("orchestrator" is the only authoritative value),
// conditions (per-target booleans keyed per CONDITION_SCHEMAS), all_conditions_met.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("./state-io");
const { CONDITION_SCHEMAS } = require("./skip-signal-resolver/condition-schemas");
const complexity = require("./skip-signal-resolver/complexity");

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
    const { appendEvents } = require("./state-io");
    const condVals = Object.values(conditions || {});
    const all_conditions_met = condVals.length > 0 && condVals.every((v) => v === true);
    // A judgment is a fact ABOUT the step, so it is its own annotation event.
    // Pre-#1733 this had to re-read the status and pass it back through markStep
    // (which replaced the whole step object) purely to avoid resetting it (#1733).
    appendEvents(sessionId, [
      {
        kind: "step_annotation",
        step: targetStep,
        key: "skip_judgment",
        value: {
          recorded_at: new Date().toISOString(),
          judgment_source: source,
          conditions: conditions || {},
          all_conditions_met,
        },
        provenance: "observed",
        origin: "record-skip-judgment",
      },
    ]);
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
  // Complexity-evaluation read side — implementation in
  // skip-signal-resolver/complexity.js, re-exported so the import path callers
  // already use stays valid.
  readComplexityEvaluation: complexity.readComplexityEvaluation,
  hasComplexityEvaluation: complexity.hasComplexityEvaluation,
  readStageComplexityLevel: complexity.readStageComplexityLevel,
  resolveSkipConditionsFromComplexity: complexity.resolveSkipConditionsFromComplexity,
};
