#!/usr/bin/env node
"use strict";

// CLI for triaging WORKTREE_NOTES.md entries before worktree cleanup.
//
// Usage:
//   node bin/worktree-notes-triage.js list <absolute-path>
//   node bin/worktree-notes-triage.js annotate <absolute-path> <lineNumber> <issueNumber>
//
// `list`     — prints a JSON array of unpromoted entries from BugsFound /
//              RelatedTasks / NextTasks (entries without the `<!-- promoted: #N -->`
//              marker). Empty array when nothing is pending.
// `annotate` — appends ` <!-- promoted: #<issueNumber> -->` to the given line,
//              writing the file atomically (tmp + rename).

const fs = require("fs");
const path = require("path");
const {
  parseSectionEntries,
  markEntryPromoted,
} = require("../hooks/lib/worktree-notes-sections");

const SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks"];

function err(msg) {
  process.stderr.write(`[worktree-notes-triage] ${msg}\n`);
}

function usage() {
  process.stderr.write(
    "Usage:\n" +
      "  worktree-notes-triage.js list <absolute-path>\n" +
      "  worktree-notes-triage.js annotate <absolute-path> <lineNumber> <issueNumber>\n"
  );
}

// Defense-in-depth: normalize collapses ".." before the split, so this rarely
// fires. The real write-confinement guarantee is basename === "WORKTREE_NOTES.md".
function hasTraversal(p) {
  return path.normalize(p).split(/[/\\]/).includes("..");
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

function cmdList(rawPath) {
  const resolved = validatePath(rawPath);
  if (!resolved) return 1;
  if (!fs.existsSync(resolved)) {
    err(`file not found: ${resolved}`);
    return 1;
  }
  const text = fs.readFileSync(resolved, "utf8");
  const out = [];
  for (const section of SECTIONS) {
    const entries = parseSectionEntries(text, section);
    for (const entry of entries) {
      out.push({
        section,
        raw: entry.raw,
        lineNumber: entry.lineNumber,
        hasMarker: entry.hasMarker,
      });
    }
  }
  process.stdout.write(JSON.stringify(out));
  return 0;
}

function cmdAnnotate(rawPath, lineNumberArg, issueNumberArg) {
  if (!/^\d+$/.test(String(lineNumberArg || ""))) {
    err(`lineNumber must be a positive integer, got: ${lineNumberArg}`);
    return 1;
  }
  if (!/^\d+$/.test(String(issueNumberArg || ""))) {
    err(`issueNumber must be a positive integer, got: ${issueNumberArg}`);
    return 1;
  }
  const lineNumber = parseInt(lineNumberArg, 10);
  const issueNumber = parseInt(issueNumberArg, 10);
  if (lineNumber < 1) {
    err(`lineNumber must be >= 1, got: ${lineNumber}`);
    return 1;
  }
  if (issueNumber < 1) {
    err(`issueNumber must be >= 1, got: ${issueNumber}`);
    return 1;
  }

  const resolved = validatePath(rawPath);
  if (!resolved) return 1;
  if (!fs.existsSync(resolved)) {
    err(`file not found: ${resolved}`);
    return 1;
  }

  const text = fs.readFileSync(resolved, "utf8");
  const updated = markEntryPromoted(text, lineNumber, issueNumber);

  const tmp = `${resolved}.tmp`;
  try {
    fs.writeFileSync(tmp, updated, "utf8");
    fs.renameSync(tmp, resolved);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* ignore cleanup error */ }
    err(`atomic write failed: ${e.message}`);
    return 1;
  }
  return 0;
}

function main() {
  const [, , cmd, filePath, ...rest] = process.argv;
  if (!cmd) {
    usage();
    return 1;
  }
  if (cmd === "list") {
    return cmdList(filePath);
  }
  if (cmd === "annotate") {
    return cmdAnnotate(filePath, rest[0], rest[1]);
  }
  err(`unknown subcommand: ${cmd}`);
  usage();
  return 1;
}

process.exit(main());
