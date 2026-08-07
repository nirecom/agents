"use strict";
// SSOT for "has the workflow actually started?" — judged by whether the
// workflow_init step is settled, not by whether a state file merely exists.
const { readState, isSettledStatus } = require("./state-io");

// Named constant for the start boundary, same convention as SENTINEL_HANG_EXEMPT_STEPS.
const WORKFLOW_START_STEP = "workflow_init";

// isWorkflowStarted(sid): true when workflow_init is settled (complete|skipped).
// Total function — never throws. Missing state / read failure / wrong shape → false.
// fail-CLOSED ("cannot prove started" = "not started"). Every consumer uses this
// in the suppression direction, so the predicate's fail-CLOSED matches the
// guard's overall fail-OPEN (see detail.md 3-5).
function isWorkflowStarted(sid) {
  try {
    const state = readState(sid);
    const step = state && state.steps && state.steps[WORKFLOW_START_STEP];
    return !!step && isSettledStatus(step.status);
  } catch (_e) {
    return false;
  }
}

module.exports = { isWorkflowStarted, WORKFLOW_START_STEP };
