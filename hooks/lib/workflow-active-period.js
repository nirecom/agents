"use strict";
// "Is this session inside its workflow active period?" — the one predicate every
// handoff writer except gate-block asks (#2430).
//
// Active = workflow_init complete, no terminal step complete, no WORKFLOW_OFF
// marker, and no unexpired pause covering the current step. Outside that period
// there is no workflow for /resume-session to resume, so a breadcrumb is noise.

const { readState, TERMINAL_STEPS, SESSION_ID_VALID_RE } = require("../workflow-state/state-io");
const { resolveCurrentEffectiveStep } = require("../workflow-state/current-step");
const { isWorkflowOff, isNextStepPaused } = require("./session-markers");

// Total and never-throw: every caller is a side-effect writer or a hook.
function isWorkflowActivePeriod(sid) {
  try {
    if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return false;
    const state = readState(sid);
    if (!state || !state.steps) return false;
    const steps = state.steps;
    if (!steps.workflow_init || steps.workflow_init.status !== "complete") return false;
    if (TERMINAL_STEPS.some((step) => steps[step] && steps[step].status === "complete")) return false;
    if (isWorkflowOff(sid)) return false;
    if (isNextStepPaused(sid, resolveCurrentEffectiveStep(sid))) return false;
    return true;
  } catch (_e) {
    return false;
  }
}

module.exports = { isWorkflowActivePeriod };
