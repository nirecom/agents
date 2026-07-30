"use strict";
// A-4 speculative-skip verdict lifecycle. Entrypoint-private to state-io.js.

const {
  assertValidSessionId,
  readState,
  writeState,
  createInitialState,
} = require("./core");

// A-4 speculative-skip verdict lifecycle. Stored as a `skip_verdict` dimension
// inside state.steps[targetStep] — sibling to skip_reason/skip_judgment. Uses
// read-modify-write (NOT markStep, which full-replaces) so co-located fields survive.
function recordSkipVerdict(sessionId, targetStep, verdict, source) {
  assertValidSessionId(sessionId);
  if (targetStep !== "outline" && targetStep !== "detail") return;
  if (verdict !== "pending" && verdict !== "confirm" && verdict !== "veto") return;
  let state = readState(sessionId);
  if (!state) {
    state = createInitialState(sessionId);
  }
  if (!state.steps[targetStep]) state.steps[targetStep] = { status: "pending", updated_at: null };
  state.steps[targetStep].skip_verdict = {
    verdict,
    source: source || "unknown",
    recorded_at: new Date().toISOString(),
  };
  writeState(sessionId, state);
}

function readSkipVerdict(sessionId, targetStep) {
  try {
    const state = readState(sessionId);
    if (!state || !state.steps || !state.steps[targetStep]) return null;
    return state.steps[targetStep].skip_verdict || null;
  } catch (_) {
    return null;
  }
}

function hasSpeculativeSkipPending(sessionId, targetStep) {
  try {
    const sv = readSkipVerdict(sessionId, targetStep);
    return sv !== null && sv.verdict === "pending";
  } catch (_) {
    return false;
  }
}

module.exports = {
  recordSkipVerdict,
  readSkipVerdict,
  hasSpeculativeSkipPending,
};
