"use strict";

// Dispatch + re-export. Logic lives in workflow-state/ submodules.
const sessionId = require("./workflow-state/session-id");
const stateIo = require("./workflow-state/state-io");
const evidenceResolver = require("./workflow-state/evidence-resolver");
const skipSignalResolver = require("./workflow-state/skip-signal-resolver");

module.exports = { ...sessionId, ...stateIo, ...evidenceResolver, ...skipSignalResolver };
