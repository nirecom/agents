"use strict";
// Complexity-evaluation read side (#1350, restructured for #2099).
//
// Everything here is CONSUMER-FACING and therefore COMPATIBILITY-COMPLETING:
// a missing or malformed per-step `levels` map is re-derived from the recorded
// signals. Read-back verification must NOT come through here — it uses
// readLastRawComplexityEvent (state-io/session-fields.js), which never folds or
// completes anything.

// Legacy shim: pre-#1382 records stored a model name in `verdict`.
const LEGACY_VERDICT_TO_LEVEL = Object.freeze({ opus: "high", sonnet: "low" });

// resolveStepLevels(level, signals, stored): a well-formed stored map is used
// as-is; a missing OR malformed one is re-derived in full (never partially
// trusted); an unusable routing table yields null so callers fail open.
function resolveStepLevels(level, signals, stored) {
  const { ROUTING_STEPS, deriveLegacyStepLevels } = require("../complexity-routing");
  if (stored && typeof stored === "object" && !Array.isArray(stored)) {
    const keys = Object.keys(stored);
    const wellFormed =
      !keys.some((k) => !ROUTING_STEPS.includes(k)) &&
      ROUTING_STEPS.every((s) => stored[s] === "high" || stored[s] === "low");
    if (wellFormed) return Object.assign({}, stored);
  }
  try {
    return Object.assign({}, deriveLegacyStepLevels(level, signals));
  } catch (_) {
    return null;
  }
}

// readComplexityEvaluation(sessionId): { level, levels, signals, recorded_at }
// or null. Fail-open: any exception → null.
function readComplexityEvaluation(sessionId) {
  try {
    const { readState } = require("../state-io");
    const state = readState(sessionId);
    if (!state) return null;
    const ce = state.complexity_evaluation;
    // --- BEGIN temporary: verdict(opus|sonnet) → level(high|low) migration ---
    let level;
    if (ce !== null && typeof ce === "object" && !("level" in ce) && typeof ce.verdict === "string") {
      // undefined for unknown legacy verdicts → validation rejects → null
      level = LEGACY_VERDICT_TO_LEVEL[ce.verdict];
    } else {
      level = ce && ce.level;
    }
    // --- END temporary: verdict(opus|sonnet) → level(high|low) migration ---
    // signals MUST be an array — consumers call ce.signals.join(); a non-array
    // would throw a TypeError downstream, so reject it here.
    if (
      !ce ||
      typeof ce !== "object" ||
      typeof level !== "string" ||
      typeof ce.recorded_at !== "string" ||
      !Array.isArray(ce.signals)
    ) {
      return null;
    }
    return {
      level,
      levels: resolveStepLevels(level, ce.signals, ce.levels),
      signals: ce.signals,
      recorded_at: ce.recorded_at,
    };
  } catch (_) {
    return null;
  }
}

// hasComplexityEvaluation(sessionId): true iff a valid evaluation exists with
// level high|low. Never throws. No mtime/staleness check (unlike
// hasValidSkipJudgment): complexity is a session-lifetime fact.
function hasComplexityEvaluation(sessionId) {
  const ce = readComplexityEvaluation(sessionId);
  if (!ce) return false;
  return ce.level === "high" || ce.level === "low";
}

// readStepComplexityLevel(sessionId, step): the level for ONE step, or null.
// Consumers pass only their own step key, so no consumer can reinterpret
// another step's threshold. Fail-open (null) on missing or underivable DATA —
// but an unknown step is a caller bug, not a data condition, so it throws a
// TypeError exactly as deriveStepLevel() does (CPR-ORTH): silently answering
// null would let a typo'd step key read as "no evaluation recorded".
function readStepComplexityLevel(sessionId, step) {
  let steps = null;
  try {
    steps = require("../complexity-routing").ROUTING_STEPS;
  } catch (_) {
    return null; // routing table unusable — the data path fails open
  }
  if (!steps.includes(step)) {
    throw new TypeError("readStepComplexityLevel: unknown step " + String(step));
  }
  try {
    const ce = readComplexityEvaluation(sessionId);
    if (!ce || !ce.levels) return null;
    const level = ce.levels[step];
    return level === "high" || level === "low" ? level : null;
  } catch (_) {
    return null;
  }
}

module.exports = {
  resolveStepLevels,
  readComplexityEvaluation,
  hasComplexityEvaluation,
  readStepComplexityLevel,
};
