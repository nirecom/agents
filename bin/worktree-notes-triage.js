#!/usr/bin/env node
"use strict";

// CLI for triaging WORKTREE_NOTES.md entries before worktree cleanup.
//
// Usage:
//   node bin/worktree-notes-triage.js list <absolute-path>
//   node bin/worktree-notes-triage.js annotate <absolute-path> <lineNumber> <issueNumber>
//   node bin/worktree-notes-triage.js resolve --caller <callsite> [...]
//
// `list`     — prints a JSON array of unpromoted entries from BugsFound /
//              RelatedTasks / NextTasks (entries without the `<!-- promoted: #N -->`
//              marker). Empty array when nothing is pending.
// `annotate` — appends ` <!-- promoted: #<issueNumber> -->` to the given line,
//              writing the file atomically (tmp + rename).
// `resolve`  — decides, per callsite, which WORKTREE_NOTES.md (if any) the
//              promotion protocol should act on. See bin/worktree-notes-triage/resolve.js.

const fs = require("fs");
const path = require("path");
const {
  parseSectionEntries,
  markEntryPromoted,
  PROMOTED_MARKER_RE,
} = require("../hooks/lib/worktree-notes-sections");
const { runResolve } = require("./worktree-notes-triage/resolve");

// Triage sections only. `## ManualReminders` is deliberately absent: a reminder
// is addressed to the person closing the session, not to a future implementer,
// so promoting one into a GitHub issue is the wrong outcome (#530).
// Deliberately NOT shared with the render-side list in
// bin/render-final-report/notes.js nor with the CLI input allowlist in
// bin/worktree-notes-append/args.js: same names, three different scopes
// (promotion targets / output sections / accepted input).
const SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks"];

function err(msg) {
  process.stderr.write(`[worktree-notes-triage] ${msg}\n`);
}

function usage() {
  process.stderr.write(
    "Usage:\n" +
      "  worktree-notes-triage.js list <absolute-path>\n" +
      "  worktree-notes-triage.js annotate <absolute-path> <lineNumber> <issueNumber>\n" +
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

function cmdList(rawPath) {
  const resolved = validatePath(rawPath);
  if (!resolved) return 1;
  if (!fs.existsSync(resolved)) {
    err(`file not found: ${resolved}`);
    return 1;
  }
  let text;
  try {
    text = fs.readFileSync(resolved, "utf8");
  } catch (e) {
    err(`cannot read ${resolved}: ${e.message}`);
    return 1;
  }
  const out = [];
  for (const section of SECTIONS) {
    const entries = parseSectionEntries(text, section);
    for (const entry of entries) {
      // Filter out already-promoted entries — they are no longer triage
      // candidates. The marker is appended by `annotate` (worktree-end Step
      // WE-11) or pre-applied by `bin/worktree-notes-append.js` (issue #622).
      if (entry.hasMarker) continue;
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

  let text;
  try {
    text = fs.readFileSync(resolved, "utf8");
  } catch (e) {
    err(`cannot read ${resolved}: ${e.message}`);
    return 1;
  }

  // Locate the target line with the same split contract markEntryPromoted uses,
  // so an out-of-range or non-entry line is refused BEFORE any write happens.
  // markEntryPromoted returns the text unchanged in those cases, which would
  // otherwise look like success.
  const parts = text.split(/(\r\n|\n)/);
  const idx = (lineNumber - 1) * 2;
  if (idx >= parts.length || typeof parts[idx] !== "string") {
    err(`lineNumber ${lineNumber} is past the end of ${resolved}`);
    return 1;
  }
  const original = parts[idx];
  if (!original.startsWith("- ")) {
    err(`line ${lineNumber} is not a notes entry: ${JSON.stringify(original)}`);
    return 1;
  }
  const existing = PROMOTED_MARKER_RE.exec(original);
  if (existing !== null) {
    // Idempotent retry: the same annotation is already recorded, so the file is
    // left byte-identical rather than growing a second marker.
    if (existing[1] === String(issueNumber)) return 0;
    err(`line ${lineNumber} is already promoted as #${existing[1]}`);
    return 1;
  }

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
  if (cmd === "resolve") {
    return runResolve(process.argv.slice(3));
  }
  err(`unknown subcommand: ${cmd}`);
  usage();
  return 1;
}

process.exit(main());
