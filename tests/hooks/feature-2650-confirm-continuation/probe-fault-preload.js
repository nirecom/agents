"use strict";
// Makes the in-process CONFIRM gate probe fail for real on the path it reads since #2726/#2729:
// config-flag.js reads the plan-stage keys (CONFIRM_INTENT/OUTLINE/DETAIL) from
// load-env.readDefaultEnvFile() only, looked up at call time.
//   "exception":  reading a plan-stage key out of the parsed config file throws (the map hides
//                 those keys from enumeration, so readers of other keys are unaffected).
//   "unreadable": fs.readFileSync of the config .env itself fails (EACCES), the real
//                 unreadable-file path inside load-env.readEnvFile.
// As a NODE_OPTIONS --require preload it arms CC_PROBE_FAULT; required in-process, arm(mode)
// returns the disarm function.
const fs = require("fs");
const path = require("path");

const le = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "load-env.js"));
const MODES = ["exception", "unreadable"];
const PLAN_KEYS = new Set(["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL"]);

function throwingPlanKeys(map) {
  const hidden = (k) => typeof k === "string" && PLAN_KEYS.has(k);
  return new Proxy(map || {}, {
    get(t, k, r) {
      if (hidden(k)) throw new Error("probe-fault-preload: config file read of " + k + " throws");
      return Reflect.get(t, k, r);
    },
    has: (t, k) => !hidden(k) && Reflect.has(t, k),
    ownKeys: (t) => Reflect.ownKeys(t).filter((k) => !hidden(k)),
    getOwnPropertyDescriptor: (t, k) => (hidden(k) ? undefined : Reflect.getOwnPropertyDescriptor(t, k)),
  });
}

function arm(mode) {
  if (!MODES.includes(mode)) throw new Error("probe-fault-preload: unknown mode " + mode);
  if (mode === "exception") {
    const orig = le.readDefaultEnvFile;
    le.readDefaultEnvFile = function (...args) { return throwingPlanKeys(orig.apply(this, args)); };
    return () => { le.readDefaultEnvFile = orig; };
  }
  const origRead = fs.readFileSync;
  const isConfigEnv = (p) => {
    try { return typeof p === "string" && path.resolve(p) === path.resolve(le.defaultEnvFilePath()); } catch (_) { return false; }
  };
  fs.readFileSync = function (p, ...rest) {
    if (isConfigEnv(p)) {
      const e = new Error("probe-fault-preload: EACCES, permission denied '" + p + "'");
      e.code = "EACCES";
      throw e;
    }
    return origRead.call(this, p, ...rest);
  };
  return () => { fs.readFileSync = origRead; };
}

if (process.env.CC_PROBE_FAULT) arm(process.env.CC_PROBE_FAULT);

module.exports = { MODES, arm };
