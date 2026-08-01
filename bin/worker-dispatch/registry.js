"use strict";
// bin/worker-dispatch/registry.js
//
// Thin binding layer between the pure-data SSOT and the worker implementations.
//
// The worker-name enum lives in hooks/lib/worker-dispatch-registry.js and is
// NEVER redefined here — the guard and the dispatcher must agree on it by
// construction, not by two lists that happen to match today. This file only
// answers "which module implements this name", which the guard neither knows
// nor needs to know.

const data = require("../../hooks/lib/worker-dispatch-registry");

// Lazy require: a worker module that is not yet implemented must not be a load
// error for the whole dispatcher, and a worker that is never dispatched should
// not pay for its dependencies.
const MODULES = {
  "test-runner": () => require("./workers/test-runner"),
  "worktree-copy": () => require("./workers/worktree-copy"),
  "worktree-backup": () => require("./workers/worktree-backup"),
  "doc-append": () => require("./workers/doc-append"),
  "issue-reconcile": () => require("./workers/issue-reconcile"),
  "session-close-gate": () => require("./workers/session-close-gate"),
  "commit-push": () => require("./workers/commit-push"),
  "issue-close-stage": () => require("./workers/issue-close-stage"),
  "issue-close-finalize": () => require("./workers/issue-close-finalize"),
};

function get(name) {
  if (typeof name !== "string") return null;
  if (!Object.prototype.hasOwnProperty.call(data.workers, name)) return null;
  return data.workers[name];
}

function loadModule(name) {
  if (!Object.prototype.hasOwnProperty.call(MODULES, name)) return null;
  const mod = MODULES[name]();
  return mod && typeof mod.run === "function" ? mod : null;
}

module.exports = {
  get,
  loadModule,
  names: data.WORKER_NAMES,
  workers: data.workers,
  data,
};
