"use strict";

// Dispatch + re-export. Logic lives in workflow-state/ submodules.
const sessionId = require("./workflow-state/session-id");
const stateIo = require("./workflow-state/state-io");
const evidenceResolver = require("./workflow-state/evidence-resolver");
const skipSignalResolver = require("./workflow-state/skip-signal-resolver");
const completionApproval = require("./workflow-state/completion-approval");
const effectiveState = require("./workflow-state/effective-state");
const inheritance = require("./workflow-state/inheritance");
const skipVerdict = require("./workflow-state/skip-verdict");

module.exports = {
  ...sessionId, ...stateIo, ...evidenceResolver, ...skipSignalResolver,
  ...completionApproval, ...effectiveState, ...inheritance, ...skipVerdict,
};
