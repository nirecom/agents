"use strict";
// NODE_OPTIONS --require preload for off-per-stage.sh: confirm-checkpoint.js's own require of
// ./workflow-state/plan-stage-table throws, as if the table could not be loaded. Every other
// caller (workflow-state/completion-approval.js loads it at startup) still gets the real module.
const Module = require("module");

const orig = Module._load;
Module._load = function (request, parent, ...rest) {
  const fromHook = parent && /[\\/]confirm-checkpoint\.js$/.test(String(parent.filename || ""));
  if (fromHook && /(^|[\\/])plan-stage-table(\.js)?$/.test(String(request))) {
    throw new Error("plan-stage-table unloadable (test stub)");
  }
  return orig.call(this, request, parent, ...rest);
};
