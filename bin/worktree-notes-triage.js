#!/usr/bin/env node
"use strict";

// CLI for triaging WORKTREE_NOTES.md entries before worktree cleanup.
// Usage: node bin/worktree-notes-triage.js <list|annotate|handoff|dispose|resolve> ...
//   list <absolute-path> — the pending entries grouped by rule-table class (#2019); see
//     bin/worktree-notes-triage/groups.js. `{}` when nothing is pending.
//   annotate <absolute-path> <lineNumber> <issueNumber> — appends ` <!-- promoted: #<issueNumber> -->`.
//   handoff <absolute-path> <lineNumber> — runs the #2488 receiver (bin/lib/finding-rules.js):
//     accepted → `disposed: handed-off`; otherwise `handoff-rejected` plus `handoff:`/`class:` lines.
//   dispose <absolute-path> <lineNumber> fixed|known-limits|discard — writes the terminal marker once.
//   resolve --caller <callsite> [...] — see bin/worktree-notes-triage/resolve.js.
// Every write is atomic (tmp + rename).

const fs = require("fs");
const path = require("path");
const {
  markEntryPromoted, markEntryDisposed, markEntryHandoffRejected, PROMOTED_MARKER_RE,
} = require("../hooks/lib/worktree-notes-sections");
const rules = require("./lib/finding-rules");
const { triageEntries, isTerminal, groupEntries } = require("./worktree-notes-triage/groups");
const { runResolve } = require("./worktree-notes-triage/resolve");

const DISPOSE_KINDS = ["fixed", "known-limits", "discard"];

function err(msg) {
  process.stderr.write(`[worktree-notes-triage] ${msg}\n`);
}

function usage() {
  process.stderr.write(
    "Usage:\n" +
      "  worktree-notes-triage.js list <absolute-path>\n" +
      "  worktree-notes-triage.js annotate <absolute-path> <lineNumber> <issueNumber>\n" +
      "  worktree-notes-triage.js handoff <absolute-path> <lineNumber>\n" +
      "  worktree-notes-triage.js dispose <absolute-path> <lineNumber> fixed|known-limits|discard\n" +
      "  worktree-notes-triage.js resolve --caller <worktree-end|session-close|issue-close-finalize> [...]\n"
  );
}

// Checked against the RAW argument, before any normalization: `path.normalize`
// collapses `..` inside an absolute path, so a normalized-then-split guard
// silently lets `<dir>/../protected/WORKTREE_NOTES.md` through.
function hasTraversal(p) {
  return String(p).split(/[/\\]/).includes("..");
}

function validatePath(rawPath) {
  if (!rawPath) {
    err("missing path argument");
    return null;
  }
  if (hasTraversal(rawPath)) {
    err(`path traversal rejected: ${rawPath}`);
    return null;
  }
  const resolved = path.resolve(rawPath);
  // Absolute check after resolve: path.resolve always returns absolute.
  if (!path.win32.isAbsolute(resolved) && !path.posix.isAbsolute(resolved)) {
    err(`path must be absolute: ${rawPath}`);
    return null;
  }
  if (hasTraversal(resolved)) {
    err(`path traversal rejected: ${rawPath}`);
    return null;
  }
  if (path.basename(resolved) !== "WORKTREE_NOTES.md") {
    err(`basename must be WORKTREE_NOTES.md, got: ${path.basename(resolved)}`);
    return null;
  }
  return resolved;
}

// { resolved, text } or null after the reason went to stderr.
function readNotes(rawPath) {
  const resolved = validatePath(rawPath);
  if (!resolved) return null;
  if (!fs.existsSync(resolved)) {
    err(`file not found: ${resolved}`);
    return null;
  }
  try {
    return { resolved, text: fs.readFileSync(resolved, "utf8") };
  } catch (e) {
    err(`cannot read ${resolved}: ${e.message}`);
    return null;
  }
}

function writeAtomic(resolved, text) {
  const tmp = `${resolved}.tmp`;
  try {
    fs.writeFileSync(tmp, text, "utf8");
    fs.renameSync(tmp, resolved);
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* ignore cleanup error */ }
    err(`atomic write failed: ${e.message}`);
    return false;
  }
}

function parseLineNumber(arg) {
  if (!/^\d+$/.test(String(arg || "")) || parseInt(arg, 10) < 1) {
    err(`lineNumber must be a positive integer, got: ${arg}`);
    return null;
  }
  return parseInt(arg, 10);
}

// The triage entry at lineNumber, or null after the reason went to stderr.
function entryAt(text, lineNumber) {
  const entry = triageEntries(text).find((e) => e.lineNumber === lineNumber);
  if (!entry) err(`line ${lineNumber} is not a triage entry`);
  return entry || null;
}

function cmdList(rawPath) {
  const notes = readNotes(rawPath);
  if (!notes) return 1;
  process.stdout.write(JSON.stringify(groupEntries(notes.text, rules.handoffAvailable())));
  return 0;
}

function cmdAnnotate(rawPath, lineNumberArg, issueNumberArg) {
  const lineNumber = parseLineNumber(lineNumberArg);
  if (lineNumber === null) return 1;
  if (!/^\d+$/.test(String(issueNumberArg || "")) || parseInt(issueNumberArg, 10) < 1) {
    err(`issueNumber must be a positive integer, got: ${issueNumberArg}`);
    return 1;
  }
  const issueNumber = parseInt(issueNumberArg, 10);
  const notes = readNotes(rawPath);
  if (!notes) return 1;

  // Refuse an out-of-range or non-entry line BEFORE any write: markEntryPromoted returns the
  // text unchanged in those cases, which would otherwise look like success.
  const parts = notes.text.split(/(\r\n|\n)/);
  const idx = (lineNumber - 1) * 2;
  if (idx >= parts.length || typeof parts[idx] !== "string") {
    err(`lineNumber ${lineNumber} is past the end of ${notes.resolved}`);
    return 1;
  }
  const original = parts[idx];
  if (!original.startsWith("- ")) {
    err(`line ${lineNumber} is not a notes entry: ${JSON.stringify(original)}`);
    return 1;
  }
  const existing = PROMOTED_MARKER_RE.exec(original);
  if (existing !== null) {
    // Idempotent retry: the same annotation leaves the file byte-identical.
    if (existing[1] === String(issueNumber)) return 0;
    err(`line ${lineNumber} is already promoted as #${existing[1]}`);
    return 1;
  }
  return writeAtomic(notes.resolved, markEntryPromoted(notes.text, lineNumber, issueNumber)) ? 0 : 1;
}

function cmdHandoff(rawPath, lineNumberArg) {
  const lineNumber = parseLineNumber(lineNumberArg);
  if (lineNumber === null) return 1;
  const notes = readNotes(rawPath);
  if (!notes) return 1;
  const entry = entryAt(notes.text, lineNumber);
  if (!entry) return 1;
  if (isTerminal(entry)) {
    process.stdout.write("handoff: skipped (entry already promoted or disposed)\n");
    return 0;
  }
  const result = rules.runHandoff(entry);
  if (result === "accepted") {
    if (!writeAtomic(notes.resolved, markEntryDisposed(notes.text, lineNumber, "handed-off"))) return 1;
    process.stdout.write("handoff: accepted\n");
    return 0;
  }
  if (!writeAtomic(notes.resolved, markEntryHandoffRejected(notes.text, lineNumber))) return 1;
  const cls = rules.classify(Object.assign({}, entry, { handoffRejected: true }), { handoffAvailable: false });
  process.stdout.write(`handoff: ${result}\nclass: ${cls}\n`);
  return 0;
}

function cmdDispose(rawPath, lineNumberArg, kind) {
  if (!DISPOSE_KINDS.includes(kind)) {
    err(`dispose kind must be one of ${DISPOSE_KINDS.join("|")}, got: ${kind}`);
    return 1;
  }
  const lineNumber = parseLineNumber(lineNumberArg);
  if (lineNumber === null) return 1;
  const notes = readNotes(rawPath);
  if (!notes) return 1;
  const entry = entryAt(notes.text, lineNumber);
  if (!entry) return 1;
  // Re-run safe: a promoted or disposed entry already has its terminal marker.
  if (isTerminal(entry)) return 0;
  return writeAtomic(notes.resolved, markEntryDisposed(notes.text, lineNumber, kind)) ? 0 : 1;
}

function main() {
  const [, , cmd, filePath, ...rest] = process.argv;
  if (!cmd) {
    usage();
    return 1;
  }
  if (cmd === "list") return cmdList(filePath);
  if (cmd === "annotate") return cmdAnnotate(filePath, rest[0], rest[1]);
  if (cmd === "handoff") return cmdHandoff(filePath, rest[0]);
  if (cmd === "dispose") return cmdDispose(filePath, rest[0], rest[1]);
  if (cmd === "resolve") return runResolve(process.argv.slice(3));
  err(`unknown subcommand: ${cmd}`);
  usage();
  return 1;
}

process.exit(main());
