"use strict";

// Dispatch + re-export. Logic lives in workflow-state/ submodules.
const sessionId = require("./workflow-state/session-id");
const stateIo = require("./workflow-state/state-io");

module.exports = { ...sessionId, ...stateIo };
