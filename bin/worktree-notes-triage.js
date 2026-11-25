#!/usr/bin/env node
"use strict";

// CLI for triaging WORKTREE_NOTES.md entries before worktree cleanup.
// Subcommands (usage() lists the argument forms):
//   list — pending entries grouped by rule-table class (#2019, worktree-notes-triage/groups.js).
//   annotate — appends ` <!-- promoted: #<issueNumber> -->`.
//   handoff — runs the #2488 receiver: accepted → `disposed: handed-off`, else `handoff-rejected`.
//   dispose fixed|discard — writes the terminal marker once; a this-pr fixed must be backed by a
//     change to its loc (bin/lib/fixed-evidence.js), else exit 2 and no write.
//   resolve — worktree-notes-triage/resolve.js; open-this-pr / check / rescope / unrescope — scope.js.
// <ref> is a 1-indexed line number or key=<8hex> (findingKey). Every write is atomic (tmp + rename).

const fs = require("fs");
const path = require("path");
const {
  markEntryPromoted, markEntryDisposed, markEntryHandoffRejected, PROMOTED_MARKER_RE,
} = require("../hooks/lib/worktree-notes-sections");
const { writeNotesAtomic } = require("../hooks/lib/worktree-notes-write");
const { findingKey } = require("../hooks/lib/finding-approval");
const rules = require("./lib/finding-rules");
const { fixedEvidence, defaultGitRunner } = require("./lib/fixed-evidence");
const { triageEntries, isTerminal, groupEntries } = require("./worktree-notes-triage/groups");
const { runResolve } = require("./worktree-notes-triage/resolve");
const { SCOPE_COMMANDS, runScope } = require("./worktree-notes-triage/scope");

const DISPOSE_KINDS = ["fixed", "discard"];

function err(msg) {
  process.stderr.write(`[worktree-notes-triage] ${msg}\n`);
}

function usage() {
  process.stderr.write(
    "Usage:\n" +
      "  worktree-notes-triage.js list <absolute-path>\n" +
      "  worktree-notes-triage.js annotate <absolute-path> <lineNumber|key=<8hex>> <issueNumber>\n" +
      "  worktree-notes-triage.js handoff <absolute-path> <lineNumber>\n" +
      "  worktree-notes-triage.js dispose <absolute-path> <lineNumber|key=<8hex>> fixed|discard\n" +
      "  worktree-notes-triage.js resolve --caller <worktree-end|session-close|issue-close-finalize> [...]\n" +
      "  worktree-notes-triage.js open-this-pr <absolute-path>\n" +
      "  worktree-notes-triage.js check <absolute-path> | check --session <session-id>\n" +
      "  worktree-notes-triage.js rescope|unrescope <absolute-path> <lineNumber|key=<8hex>>\n"
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

const writeAtomic = (resolved, text) => writeNotesAtomic(resolved, text, err);

function parseLineNumber(arg) {
  if (!/^\d+$/.test(String(arg || "")) || parseInt(arg, 10) < 1) {
    err(`lineNumber must be a positive integer, got: ${arg}`);
    return null;
  }
  return parseInt(arg, 10);
}

// A line number, or the one triage entry whose findingKey is the key=<8hex> ref; null after stderr.
function resolveEntryRef(text, ref) {
  const s = String(ref || "");
  if (!s.startsWith("key=")) return parseLineNumber(s);
  const m = /^key=([0-9a-f]{8})$/.exec(s);
  if (m === null) {
    err(`key ref must be key=<8 lowercase hex>, got: ${s}`);
    return null;
  }
  const hits = triageEntries(text).filter((e) => findingKey(e.section, e.body) === m[1]);
  if (hits.length !== 1) {
    err(`key=${m[1]} matches ${hits.length} entries; use the line number`);
    return null;
  }
  return hits[0].lineNumber;
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

function cmdAnnotate(rawPath, refArg, issueNumberArg) {
  if (!/^\d+$/.test(String(issueNumberArg || "")) || parseInt(issueNumberArg, 10) < 1) {
    err(`issueNumber must be a positive integer, got: ${issueNumberArg}`);
    return 1;
  }
  const issueNumber = parseInt(issueNumberArg, 10);
  const notes = readNotes(rawPath);
  if (!notes) return 1;
  const lineNumber = resolveEntryRef(notes.text, refArg);
  if (lineNumber === null) return 1;

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

function cmdDispose(rawPath, refArg, kind) {
  if (!DISPOSE_KINDS.includes(kind)) {
    err(`dispose kind must be one of ${DISPOSE_KINDS.join("|")}, got: ${kind}`);
    return 1;
  }
  const notes = readNotes(rawPath);
  if (!notes) return 1;
  const lineNumber = resolveEntryRef(notes.text, refArg);
  if (lineNumber === null) return 1;
  const entry = entryAt(notes.text, lineNumber);
  if (!entry) return 1;
  // Re-run safe: a promoted or disposed entry already has its terminal marker.
  if (isTerminal(entry)) return 0;
  if (kind === "fixed" && entry.prScope === "this-pr") {
    const ev = fixedEvidence(entry, defaultGitRunner(path.dirname(notes.resolved)));
    if (!ev.ok) {
      err(`dispose fixed refused: fixed-unverified: ${ev.reason}${ev.path ? ` ${ev.path}` : ""} — change that path first, or settle the finding another way (check <path> lists the exits)`);
      return 2;
    }
  }
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
  if (SCOPE_COMMANDS.includes(cmd)) {
    return runScope({ validatePath, readNotes, resolveEntryRef, write: writeAtomic, err }, cmd, process.argv.slice(3));
  }
  err(`unknown subcommand: ${cmd}`);
  usage();
  return 1;
}

process.exit(main());
