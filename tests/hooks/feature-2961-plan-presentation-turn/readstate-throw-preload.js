"use strict";
// #2961 child preload (NODE_OPTIONS=--require): when CC_READSTATE_THROW=1, the supervisor state
// reader throws, so acceptedOnError (the judgment's error exit) throws as well. Paired with
// tests/lib/artifact-key-throw-preload.js it drives the gate's runId-less auditError path; the
// in-process twin is common.js withReadStateThrow.
const path = require("path");

if (process.env.CC_READSTATE_THROW === "1") {
  const w = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "supervisor-state-writer"));
  w.readState = () => { throw new Error("fixture: readState failed (CC_READSTATE_THROW)"); };
}
