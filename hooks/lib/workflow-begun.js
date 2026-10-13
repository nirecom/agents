"use strict";
// Answers "has this session's WF begun?" for the commit gate (#1633).
// Distinct from lifecycle.isWorkflowStarted (settlement + adoption origin) and
// workflow-active-period.isWorkflowActivePeriod (only complete counts): here
// "begun" means the gate now inspects this session's commits — workflow_init is
// in_progress, complete, or any other non-pending status.

const fs = require("fs");

function readWorkflowBegun(sessionId) {
  let getStatePath, readState, SESSION_ID_VALID_RE;
  try {
    ({ SESSION_ID_VALID_RE, getStatePath, readState } = require("../workflow-state"));
  } catch (_) {
    return { verdict: "unknown", reason: "state-unreadable", state: null };
  }

  if (typeof sessionId !== "string" || !SESSION_ID_VALID_RE.test(sessionId)) {
    return { verdict: "unknown", reason: "invalid-session-id", state: null };
  }

  let statePath;
  try {
    statePath = getStatePath(sessionId);
  } catch (_) {
    return { verdict: "unknown", reason: "invalid-session-id", state: null };
  }

  if (!fs.existsSync(statePath)) {
    return { verdict: "not-begun", reason: "no-state", state: null };
  }

  const state = readState(sessionId);
  if (!state) {
    return { verdict: "unknown", reason: "state-unreadable", state: null };
  }

  const wfInit = state.current && state.current.steps && state.current.steps.workflow_init;
  const status = wfInit ? wfInit.status : "pending";

  if (status === "pending") {
    return { verdict: "not-begun", reason: "workflow-init-pending", state };
  }
  // Any recorded non-pending status counts as begun (fail-closed).
  return { verdict: "begun", reason: status, state };
}

module.exports = { readWorkflowBegun };
