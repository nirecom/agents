"use strict";
// A-4 speculative-skip verdict lifecycle. Entrypoint-private to state-io.js.

const { assertValidSessionId, readState } = require("./core");
const { appendEvents } = require("./events");

// A-4 speculative-skip verdict lifecycle. Stored as a `skip_verdict` annotation on
// the target step — sibling to skip_reason/skip_judgment. It is a fact ABOUT the
// step, not the step's status, so it is appended as its own annotation event and
// the recorded status is left exactly where it was (#1733).
function recordSkipVerdict(sessionId, targetStep, verdict, source) {
  assertValidSessionId(sessionId);
  if (targetStep !== "outline" && targetStep !== "detail") return;
  if (verdict !== "pending" && verdict !== "confirm" && verdict !== "veto") return;
  appendEvents(sessionId, [
    {
      kind: "step_annotation",
      step: targetStep,
      key: "skip_verdict",
      value: {
        verdict,
        source: source || "unknown",
        recorded_at: new Date().toISOString(),
      },
      provenance: "observed",
      origin: "record-skip-verdict",
    },
  ]);
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
