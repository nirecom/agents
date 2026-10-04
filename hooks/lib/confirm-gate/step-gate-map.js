"use strict";
// SSOT: which CONFIRM_* gate guards each workflow step, and the default each gate
// is probed with. Confirm gates only — unrelated to STAGE_FOR_STEP / APPROVAL_GATED_STEPS.

const CONFIRM_GATE_FOR_STEP = Object.freeze({
  clarify_intent: "CONFIRM_INTENT",
  outline: "CONFIRM_OUTLINE",
  detail: "CONFIRM_DETAIL",
  write_tests: "CONFIRM_TESTS",
  write_code: "CONFIRM_CODE",
  docs: "CONFIRM_DOCS",
  branching_complete: "CONFIRM_WORKTREE",
});

const CONFIRM_GATE_DEFAULTS = Object.freeze({
  CONFIRM_INTENT: "on",
  CONFIRM_OUTLINE: "on",
  CONFIRM_DETAIL: "on",
  CONFIRM_TESTS: "on",
  CONFIRM_CODE: "on",
  CONFIRM_DOCS: "on",
  CONFIRM_WORKTREE: "on",
});

function confirmGateForStep(step) {
  return Object.prototype.hasOwnProperty.call(CONFIRM_GATE_FOR_STEP, step)
    ? CONFIRM_GATE_FOR_STEP[step]
    : null;
}

module.exports = { CONFIRM_GATE_FOR_STEP, CONFIRM_GATE_DEFAULTS, confirmGateForStep };
