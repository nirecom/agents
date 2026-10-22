"use strict";
// Preloaded with node --require: every CONFIRM_* probe answers ERROR, so planGateState returns
// ERROR whatever the config file says (#2729: the Stop guard treats ERROR like ON).
const path = require("path");

const probe = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "confirm-gate", "probe.js"));
probe.probeConfirmGateWithCause = () => ({ value: "ERROR", cause: "exception" });
probe.probeConfirmGateSync = () => "ERROR";
probe.probeConfirmGate = () => Promise.resolve("ERROR");
