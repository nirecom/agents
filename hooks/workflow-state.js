"use strict";

// Dispatch + re-export. Logic lives in workflow-state/ submodules.
const sessionId = require("./workflow-state/session-id");
const stateIo = require("./workflow-state/state-io");
const evidenceResolver = require("./workflow-state/evidence-resolver");
const skipSignalResolver = require("./workflow-state/skip-signal-resolver");
const complexityRouting = require("./workflow-state/complexity-routing");
const completionApproval = require("./workflow-state/completion-approval");
const effectiveState = require("./workflow-state/effective-state");
const inheritance = require("./workflow-state/inheritance");
const skipVerdict = require("./workflow-state/skip-verdict");
const mergeBaseBaseline = require("./workflow-state/merge-base-baseline");
const lifecycle = require("./workflow-state/lifecycle");
const currentStep = require("./workflow-state/current-step");

// Spread order carries no meaning here: since #1305 removed state-io's duplicate
// findLatestStateForContext, no two submodules export the same name.
module.exports = {
  ...sessionId, ...stateIo, ...evidenceResolver, ...skipSignalResolver, ...complexityRouting,
  ...completionApproval, ...effectiveState, ...inheritance, ...skipVerdict,
  ...mergeBaseBaseline, ...lifecycle, ...currentStep,
};
