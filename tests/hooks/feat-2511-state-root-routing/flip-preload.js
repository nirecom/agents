"use strict";
// Loaded with NODE_OPTIONS=--require=<this file> by lock-cases.sh R22d: every call to
// getSessionStateDir answers the other root (legacy, new, legacy, ...), so each lock
// re-acquire sees the state "move" again and the MAX_REACQUIRE limit must end the loop.
// It patches module.exports before any consumer loads, because core.js and
// control-dir.js destructure getSessionStateDir at require time.
const os = require("os");
const path = require("path");

const A = path.resolve(__dirname, "..", "..", "..");
const sr = require(path.join(A, "hooks", "workflow-state", "state-io", "state-root.js"));
const { LEGACY_ROOT } = require(path.join(A, "hooks", "lib", "temporary-migrations", "state-dir-relocation", "legacy.js"));

let legacyNext = true;
sr.getSessionStateDir = function flippingSessionStateDir(sid, opts) {
  sr.assertValidStateSid(sid);
  const answer = legacyNext ? LEGACY_ROOT((opts && opts.home) || os.homedir()) : sr.getStateRoot(opts);
  legacyNext = !legacyNext;
  return answer;
};
