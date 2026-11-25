"use strict";

// this-pr subcommands of bin/worktree-notes-triage.js (#3145):
//   open-this-pr <path> — JSON {state, open, reason}; exit 0 for ok/absent, 1 for error.
//   check <path> | check --session <sid> — exit 0 silent when nothing is open, 2 with the refusal
//     (stdout), 1 when the notes cannot be checked (stderr).
//   rescope <path> <ref> — this-pr-unfixed / fixed-unverified only; unrescope <path> <ref> — rescoped only.
// io carries the CLI's validatePath / readNotes / resolveEntryRef / write / err.

const {
  readOpenThisPr, formatOpenThisPrRefusal, formatDegradedRefusal, resolveSessionNotesPath,
} = require("../lib/this-pr-open");
const { markEntryRescoped, markEntryUnrescoped } = require("../../hooks/lib/worktree-notes-sections");
const { triageEntries } = require("./groups");

const RESCOPABLE = Object.freeze(["this-pr-unfixed", "fixed-unverified"]);

function cmdOpenThisPr(io, rawPath) {
  const resolved = io.validatePath(rawPath);
  if (!resolved) return 1;
  const r = readOpenThisPr(resolved);
  process.stdout.write(JSON.stringify({ state: r.state, open: r.open, reason: r.reason }));
  return r.state === "error" ? 1 : 0;
}

function cmdCheck(io, args) {
  let resolved;
  if (args[0] === "--session") {
    const res = resolveSessionNotesPath(args[1]);
    if (res.error) {
      process.stderr.write(`${formatDegradedRefusal(res.error)}\n`);
      return 1;
    }
    resolved = res.path;
  } else {
    resolved = io.validatePath(args[0]);
    if (!resolved) return 1;
  }
  const r = readOpenThisPr(resolved);
  if (r.state === "error") {
    process.stderr.write(`${formatDegradedRefusal(r.reason)}\n`);
    return 1;
  }
  if (r.open.length === 0) return 0;
  process.stdout.write(`${formatOpenThisPrRefusal(resolved, r.open)}\n`);
  return 2;
}

// {notes, lineNumber, entry} for the ref, or null after the reason went to stderr.
function target(io, rawPath, ref) {
  const notes = io.readNotes(rawPath);
  if (!notes) return null;
  const lineNumber = io.resolveEntryRef(notes.text, ref);
  if (lineNumber === null) return null;
  const entry = triageEntries(notes.text).find((e) => e.lineNumber === lineNumber);
  if (!entry) {
    io.err(`line ${lineNumber} is not a triage entry`);
    return null;
  }
  return { notes, lineNumber, entry };
}

function cmdRescope(io, rawPath, ref) {
  const t = target(io, rawPath, ref);
  if (!t) return 1;
  const open = readOpenThisPr(t.notes.resolved).open.find((o) => o.lineNumber === t.lineNumber);
  if (!open || !RESCOPABLE.includes(open.reason)) {
    io.err(`line ${t.lineNumber} is not an unsettled this-pr finding (${open ? open.reason : "settled or not this-pr"})`);
    return 1;
  }
  return io.write(t.notes.resolved, markEntryRescoped(t.notes.text, t.lineNumber)) ? 0 : 1;
}

function cmdUnrescope(io, rawPath, ref) {
  const t = target(io, rawPath, ref);
  if (!t) return 1;
  if (t.entry.rescopedFrom !== "this-pr") {
    io.err(`line ${t.lineNumber} was never rescoped from this-pr`);
    return 1;
  }
  return io.write(t.notes.resolved, markEntryUnrescoped(t.notes.text, t.lineNumber)) ? 0 : 1;
}

const SCOPE_COMMANDS = Object.freeze(["open-this-pr", "check", "rescope", "unrescope"]);

function runScope(io, cmd, args) {
  if (cmd === "open-this-pr") return cmdOpenThisPr(io, args[0]);
  if (cmd === "check") return cmdCheck(io, args);
  if (cmd === "rescope") return cmdRescope(io, args[0], args[1]);
  return cmdUnrescope(io, args[0], args[1]);
}

module.exports = { SCOPE_COMMANDS, runScope };
