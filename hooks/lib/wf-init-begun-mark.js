"use strict";
// The one recorder of "wf-init was invoked" (#1633): marks workflow_init
// in_progress. Shared by hooks/postuse-step-in-flight-mark.js (Skill dispatch) and
// hooks/user-prompt-submit-wf-init-mark.js (typed slash command), which must not
// call markStep for workflow_init themselves.

const fs = require("fs");

function markWorkflowInitBegun(sid) {
  const { getStatePath, readState, markStep, LOOKAHEAD_ORIGIN } = require("../workflow-state");

  if (fs.existsSync(getStatePath(sid))) {
    require("../workflow-state/cycle-state").closeCycleIfFinished(sid, "reinit-entry");
    const state = readState(sid);
    // Corrupt state is left untouched: the mechanism-failure reporter needs that evidence.
    if (state === null) return;
    const wfInit = state.current && state.current.steps && state.current.steps.workflow_init;
    if ((wfInit ? wfInit.status : "pending") !== "pending") return;
  }
  markStep(sid, "workflow_init", "in_progress", {}, {
    provenance: "observed",
    origin: LOOKAHEAD_ORIGIN,
  });
}

module.exports = { markWorkflowInitBegun };
