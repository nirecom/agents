"use strict";

// Dispatch + re-export. Logic lives in workflow-state/ submodules.
const sessionId = require("./workflow-state/session-id");
const stateIo = require("./workflow-state/state-io");
const evidenceResolver = require("./workflow-state/evidence-resolver");

module.exports = { ...sessionId, ...stateIo, ...evidenceResolver };
