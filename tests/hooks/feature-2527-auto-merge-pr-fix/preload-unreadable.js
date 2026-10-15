"use strict";
// Test preload (not a test), loaded with NODE_OPTIONS=--require: makes AUTO_MERGE_PR unreadable
// in the process it is loaded into. resolveConfigVar answers AUTO_MERGE_PR with loadFailed:true —
// the shape hooks/lib/load-env.js returns when loadDefaultEnv throws, which a real fixture cannot
// provoke (every file read in load-env is caught) — and resolves every other key unchanged.

const path = require("path");

const loadEnv = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "load-env.js"));
const original = loadEnv.resolveConfigVar;
loadEnv.resolveConfigVar = function resolveConfigVarUnreadable(name, defaultValue, opts) {
  if (name === "AUTO_MERGE_PR") return { value: defaultValue || "", loadFailed: true, source: "default" };
  return original.call(this, name, defaultValue, opts);
};
