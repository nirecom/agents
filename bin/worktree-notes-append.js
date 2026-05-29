#!/usr/bin/env node
"use strict";

// CLI for appending a new issue reference to WORKTREE_NOTES.md (issue #622).
//
// Usage:
//   node bin/worktree-notes-append.js \
//     --notes-path <absolute-path-to-WORKTREE_NOTES.md> \
//     --issue-number <N> \
//     --title "<short title>" \
//     [--label <label> [--label ...]] \
//     [--skip-if-main]
//
// Routes to ## BugsFound when any --label is type:incident, else ## RelatedTasks.
// Idempotent: re-running with the same --issue-number is a no-op (no duplicate).
// Atomic write via tmp + rename. Pre-marks the new entry with
// ` <!-- promoted: #<N> -->` so the triage list filter treats it as resolved.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { parseArgs } = require("util");
const {
  parseSectionEntries,
} = require("../hooks/lib/worktree-notes-sections");

function err(msg) {
  process.stderr.write(`[worktree-notes-append] ${msg}\n`);
}

function hasTraversal(p) {
  // Reject any ".." segment in the raw input, before normalize collapses it.
  // Defense-in-depth against `<tmp>/../WORKTREE_NOTES.md` style inputs that
  // would otherwise resolve to a path outside the intended directory.
  const rawSegments = String(p).split(/[/\\]/);
  if (rawSegments.includes("..")) return true;
  return path.normalize(p).split(/[/\\]/).includes("..");
}

function validatePath(rawPath) {
  if (!rawPath) {
    err("missing --notes-path");
    return null;
  }
  if (hasTraversal(rawPath)) {
    err(`path traversal rejected: ${rawPath}`);
    return null;
  }
  const resolved = path.resolve(rawPath);
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

function isMainWorktree(notesDir) {
  // Returns true when the directory containing WORKTREE_NOTES.md is the main
  // worktree of its git repo. False when not in a git repo or in a linked
  // worktree. Errors are swallowed (best-effort skip).
  const result = spawnSync("git", ["-C", notesDir, "rev-parse", "--git-common-dir"], {
    encoding: "utf8",
  });
  if (result.status !== 0) return false;
  const raw = (result.stdout || "").trim();
  if (!raw) return false;
  const resolvedCommonDir = path.resolve(notesDir, raw);
  // Both main and linked worktrees report the main repo's `.git` directory
  // (resolved absolute). The main worktree path is its parent.
  const mainWorktreePath = path.dirname(resolvedCommonDir);
  return path.resolve(notesDir) === path.resolve(mainWorktreePath);
}

function targetSectionForLabels(labels) {
  for (const l of labels) {
    if (l === "type:incident") return "BugsFound";
  }
  return "RelatedTasks";
}

function detectEol(text) {
  return text.includes("\r\n") ? "\r\n" : "\n";
}

// Strip optional trailing \r so equality checks work for CRLF input.
function trimCR(line) {
  return line.endsWith("\r") ? line.slice(0, -1) : line;
}

// Compose the file with a brand-new section when the file is absent.
function composeFreshFile(section, newLine, eol) {
  return `# Worktree Notes${eol}${eol}## ${section}${eol}${newLine}${eol}`;
}

function appendSectionAtEof(text, section, newLine, eol) {
  let base = text;
  // Normalize trailing newline so the new heading does not glue.
  if (base.length > 0 && !base.endsWith("\n")) {
    base += eol;
  }
  return `${base}${eol}## ${section}${eol}${newLine}${eol}`;
}

// Insert newLine into an existing section. Either replaces the "- (none)"
// placeholder or inserts before the next heading / EOF.
function insertIntoExistingSection(text, section, newLine, eol) {
  // Split on \n keeping any trailing \r on each line.
  const lines = text.split("\n");
  let sectionIdx = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (trimCR(lines[i]) === `## ${section}`) {
      sectionIdx = i;
      break;
    }
  }
  if (sectionIdx === -1) {
    // Caller already verified section exists; defensive fallback.
    return appendSectionAtEof(text, section, newLine, eol);
  }

  // Search within the section for "- (none)" or the next heading.
  let noneIdx = -1;
  let nextHeadingIdx = -1;
  for (let i = sectionIdx + 1; i < lines.length; i += 1) {
    const stripped = trimCR(lines[i]);
    if (stripped.startsWith("## ") || stripped.startsWith("### ")) {
      nextHeadingIdx = i;
      break;
    }
    if (stripped === "- (none)") {
      noneIdx = i;
      break;
    }
  }

  // The new line, formatted to match the prevailing EOL. Lines kept in the
  // split array use \n as separator on join, so include \r where appropriate.
  const newLineFormatted = eol === "\r\n" ? `${newLine}\r` : newLine;

  if (noneIdx !== -1) {
    lines[noneIdx] = newLineFormatted;
    return lines.join("\n");
  }

  if (nextHeadingIdx !== -1) {
    lines.splice(nextHeadingIdx, 0, newLineFormatted);
    return lines.join("\n");
  }

  // Section runs to EOF. Append the new line just before any trailing blank.
  // Find last non-blank index after sectionIdx.
  let insertAt = lines.length;
  // If the file ends with a trailing newline, split produces a trailing
  // empty element; insert before it to preserve trailing newline.
  if (lines.length > 0 && trimCR(lines[lines.length - 1]) === "") {
    insertAt = lines.length - 1;
  }
  lines.splice(insertAt, 0, newLineFormatted);
  return lines.join("\n");
}

function sectionPresent(text, section) {
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    if (line === `## ${section}`) return true;
  }
  return false;
}

function entryAlreadyPresent(text, section, issueNumber) {
  if (!text) return false;
  const entries = parseSectionEntries(text, section);
  const marker = `(#${issueNumber})`;
  for (const entry of entries) {
    if (entry.raw.includes(marker)) return true;
  }
  return false;
}

function parseCliArgs(argv) {
  try {
    const { values } = parseArgs({
      args: argv,
      options: {
        "notes-path": { type: "string" },
        "issue-number": { type: "string" },
        title: { type: "string" },
        label: { type: "string", multiple: true },
        "skip-if-main": { type: "boolean" },
      },
      strict: true,
      allowPositionals: false,
    });
    return values;
  } catch (e) {
    err(`argument parse failed: ${e.message}`);
    return null;
  }
}

function main() {
  const args = parseCliArgs(process.argv.slice(2));
  if (!args) return 2;

  const notesPathRaw = args["notes-path"];
  const issueNumberRaw = args["issue-number"];
  const title = args.title;
  const labels = Array.isArray(args.label) ? args.label : [];
  const skipIfMain = Boolean(args["skip-if-main"]);

  if (!notesPathRaw) {
    err("missing --notes-path");
    return 2;
  }
  if (!issueNumberRaw || !/^\d+$/.test(String(issueNumberRaw))) {
    err(`invalid --issue-number: ${issueNumberRaw}`);
    return 2;
  }
  if (typeof title !== "string" || title.length === 0) {
    err("missing --title");
    return 2;
  }
  if (title.includes("<!--") || title.includes("\n") || title.includes("\r")) {
    err("invalid title");
    return 2;
  }

  const resolved = validatePath(notesPathRaw);
  if (!resolved) return 2;

  const issueNumber = parseInt(issueNumberRaw, 10);

  if (skipIfMain) {
    const notesDir = path.dirname(resolved);
    try {
      if (isMainWorktree(notesDir)) {
        return 0;
      }
    } catch {
      // Not in a git repo or git missing — proceed silently.
    }
  }

  const section = targetSectionForLabels(labels);

  let text = "";
  try {
    text = fs.readFileSync(resolved, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") {
      text = "";
    } else {
      err(`read failed: ${e.message}`);
      return 1;
    }
  }

  // Idempotency: skip silently when the issue is already recorded in the
  // target section.
  if (text.length > 0 && entryAlreadyPresent(text, section, issueNumber)) {
    return 0;
  }

  const eol = detectEol(text);
  const newLine = `- ${title} (#${issueNumber}) <!-- promoted: #${issueNumber} -->`;

  let updated;
  if (text.length === 0) {
    updated = composeFreshFile(section, newLine, eol);
  } else if (!sectionPresent(text, section)) {
    updated = appendSectionAtEof(text, section, newLine, eol);
  } else {
    updated = insertIntoExistingSection(text, section, newLine, eol);
  }

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

process.exit(main());
