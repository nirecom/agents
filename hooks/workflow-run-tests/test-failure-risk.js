"use strict";
// A failing suite after implementation is a handoff risk (#2430): it stamps the
// risk signal that halves the omission-check nudge limits.

const { resolveCurrentEffectiveStep } = require("../workflow-state/current-step");
const { recordRiskSignal } = require("../lib/handoff-risk-signal");

// Named exception: during these steps a red suite is the expected TDD state, not
// a sign that working knowledge is at risk — stamping it would keep the nudge
// limits halved for the whole phase.
const RED_EXPECTED_STEPS = Object.freeze(["write_tests", "review_tests", "write_code"]);

// Never throws. When the current step cannot be resolved nothing is stamped:
// the exception cannot be ruled out, and a missed stamp only delays a nudge.
function stampTestFailureRisk(sessionId) {
  try {
    const step = resolveCurrentEffectiveStep(sessionId);
    if (typeof step !== "string" || step.length === 0) return false;
    if (RED_EXPECTED_STEPS.includes(step)) return false;
    return recordRiskSignal(sessionId, "test-failure") === true;
  } catch (_e) {
    return false;
  }
}

module.exports = { RED_EXPECTED_STEPS, stampTestFailureRisk };
