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

// Runtimes the supported test languages launch: launch.requires + launch.command[0].
// Fail-closed: an unreadable language table derives nothing, so pwsh & co. stay denied.
function testLanguageRuntimes() {
  let reg = null;
  try {
    reg = require("../../hooks/lib/test-language-registry").tryLoadRegistry();
  } catch (_e) {
    reg = null;
  }
  const out = [];
  if (!reg || !Array.isArray(reg.entries)) return out;
  for (const e of reg.entries) {
    if (!e || e.status !== "supported" || !e.launch) continue;
    const { requires, command } = e.launch;
    if (typeof requires === "string" && requires !== "") out.push(requires);
    if (Array.isArray(command) && typeof command[0] === "string" && command[0] !== "") out.push(command[0]);
  }
  return out;
}

// A worker's declared external commands, plus the derived runtimes when it opts in with
// `binaries.externalFromTestLanguages: true` (strictly boolean; anything else is ignored).
function effectiveExternal(entry) {
  const b = entry && entry.binaries ? entry.binaries : {};
  const declared = Array.isArray(b.external) ? b.external : [];
  const derived = b.externalFromTestLanguages === true ? testLanguageRuntimes() : [];
  return Array.from(new Set(declared.concat(derived)));
}

// The dispatcher-wide table: the hand list EXTERNAL_COMMANDS plus every worker's effective set.
function effectiveExternalCommands() {
  let all = data.EXTERNAL_COMMANDS.slice();
  for (const name of Object.keys(data.workers)) all = all.concat(effectiveExternal(data.workers[name]));
  return Array.from(new Set(all));
}

module.exports = {
  get,
  loadModule,
  effectiveExternal,
  effectiveExternalCommands,
  names: data.WORKER_NAMES,
  workers: data.workers,
  data,
};
