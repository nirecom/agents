"use strict";
// Makes the in-process CONFIRM gate probe fail for real: hooks/lib/load-env.js resolveConfigVar
// (which config-flag.js looks up at call time) throws ("exception") or reports loadFailed
// ("load-failed") for CONFIRM_* keys, the two failures config-flag maps to kind "failed".
// Other keys resolve normally. As a NODE_OPTIONS --require preload it arms CC_PROBE_FAULT;
// required in-process, arm(mode) returns the disarm function.
const path = require("path");

const le = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "load-env.js"));
const MODES = ["exception", "load-failed"];

function arm(mode) {
  if (!MODES.includes(mode)) throw new Error("probe-fault-preload: unknown mode " + mode);
  const orig = le.resolveConfigVar;
  le.resolveConfigVar = function (name, ...rest) {
    if (!/^CONFIRM_/.test(String(name))) return orig.call(this, name, ...rest);
    if (mode === "exception") throw new Error("probe-fault-preload: resolveConfigVar throws");
    return Object.assign({}, orig.call(this, name, ...rest), { loadFailed: true });
  };
  return () => { le.resolveConfigVar = orig; };
}

if (process.env.CC_PROBE_FAULT) arm(process.env.CC_PROBE_FAULT);

module.exports = { MODES, arm };
