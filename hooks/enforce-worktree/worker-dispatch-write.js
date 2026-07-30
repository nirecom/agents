"use strict";
// hooks/enforce-worktree/worker-dispatch-write.js
//
// Write predicate for the plain-script worker dispatcher (#1643).
//
// Why this exists: enforce-worktree.js exits early — ALLOW — as soon as
// detectWritePredicate() reports a read-only command, which happens BEFORE any
// main-worktree allow predicate runs. A bare `node "<acd>/bin/worker-dispatch.js"
// <worker> <main-root> <payload>` carries no redirect and no git subcommand, so
// without this predicate it is classified read-only and the worker-dispatch
// overlay's Locks 1/2/3 never execute at all. (The pre-existing SANCTIONED
// entries only reach the overlay because they carry log redirects.)
//
// A worker dispatch is a write by definition: workers copy worktree state, append
// docs, and write plans-dir artifacts. Classifying it as a write is what routes it
// through the guard rather than around it.
//
// Scope is INVOCATION, not mention: the script path must sit in command position
// or be the script argument of an interpreter/wrapper. Reading or grepping the
// dispatcher source from the main worktree stays read-only.

const path = require("path");

const DISPATCH_BASENAME = "worker-dispatch.js";

// Command words that execute their argument. `env`/`command`/`exec`/`nohup`/
// `timeout`/`xargs`/`sudo`/`doas` are wrappers: they do not run the file
// themselves but hand it to something that does, and the argv scan below is
// position-agnostic, so one entry covers every nesting of them.
const INVOKERS = new Set([
  "node", "nodejs",
  "bash", "sh", "zsh", "dash", "ksh",
  "pwsh", "powershell",
  "python", "python3", "perl", "ruby",
  "env", "eval", "exec", "command", "nohup", "timeout", "xargs",
  "sudo", "doas",
]);

// Basename, lowercased, with a Windows executable suffix removed so `node.exe`
// and `node` are the same command word.
function commandWord(tok) {
  if (typeof tok !== "string" || tok === "") return "";
  const base = path.basename(tok.replace(/["']/g, "")).toLowerCase();
  return base.replace(/\.(exe|cmd|bat|ps1)$/, "");
}

function isDispatchPath(tok) {
  if (typeof tok !== "string" || tok === "") return false;
  return path.basename(tok.replace(/["']/g, "")).toLowerCase() === DISPATCH_BASENAME;
}

function segmentInvokes(argv) {
  if (!Array.isArray(argv) || argv.length === 0) return false;
  // Command position: the dispatcher executed directly (shebang / interpreter
  // resolved by the OS).
  if (isDispatchPath(argv[0])) return true;
  if (!INVOKERS.has(commandWord(argv[0]))) return false;
  for (let i = 1; i < argv.length; i += 1) {
    if (isDispatchPath(argv[i])) return true;
  }
  return false;
}

/**
 * True when the command invokes bin/worker-dispatch.js in any shape — including
 * the shapes the overlay refuses. Refused shapes MUST still be detected here:
 * that is what makes them reach the main-worktree block instead of the
 * read-only early exit.
 */
function isWorkerDispatchWriteIR(ir) {
  if (!ir || typeof ir !== "object") return false;
  const segments = Array.isArray(ir.segments) && ir.segments.length > 0
    ? ir.segments
    : [ir];
  for (const seg of segments) {
    if (seg && segmentInvokes(seg.argv)) return true;
  }
  return false;
}

module.exports = { isWorkerDispatchWriteIR, DISPATCH_BASENAME };
