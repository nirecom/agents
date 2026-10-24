"use strict";
// The planning-phase rule shared by lang-inject.js (UserPromptSubmit) and post-compact.js (#2240):
// a session is planning while any planning step is neither complete nor skipped.

const { readState } = require("../workflow-state");

const PLAN_STEPS = ["clarify_intent", "outline", "detail"];

// Fail-open to false on a missing session id or a state-read failure.
function isPlanning(sessionId) {
  if (!sessionId) return false;
  try {
    const state = readState(sessionId);
    if (!state || !state.steps) return false;
    return PLAN_STEPS.some((step) => {
      const s = (state.steps[step] || {}).status || "pending";
      return s !== "complete" && s !== "skipped";
    });
  } catch (_e) {
    return false;
  }
}

module.exports = { PLAN_STEPS, isPlanning };
