#!/usr/bin/env node
"use strict";

// CLI for appending an entry to WORKTREE_NOTES.md. Argument parsing and mode
// resolution live in bin/worktree-notes-append/args.js.
//
// Mode A (--issue-number given): promotion pointer for an existing issue (#622)
//   — routes to BugsFound for a type:incident label, else RelatedTasks; idempotent on (#N).
// Mode B (--issue-number omitted): finding authoring (#1886) via --section/--title
//   [--severity high|low|none]; severity required only for BugsFound, and `high`
//   is kept verbatim in the Final Report; idempotent on the entry body.
//
// Both modes: atomic write via tmp + rename, `- (none)` placeholder replacement,
// missing-section append at EOF.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const {
  parseSectionEntries,
} = require("../hooks/lib/worktree-notes-sections");
const { resolveArgs } = require("./worktree-notes-append/args");

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

// Mode A idempotency: keyed on the `(#N)` back-reference in the raw line.
function entryAlreadyPresent(text, section, issueNumber) {
  if (!text) return false;
  const entries = parseSectionEntries(text, section);
  const marker = `(#${issueNumber})`;
  for (const entry of entries) {
    if (entry.raw.includes(marker)) return true;
  }
  return false;
}

// Mode B idempotency: keyed on the stripped entry body, so re-running with a
// different --severity does not append an untagged duplicate of a tagged entry.
function bodyAlreadyPresent(text, section, title) {
  if (!text) return false;
  const wanted = title.trim();
  for (const entry of parseSectionEntries(text, section)) {
    if (entry.body === wanted) return true;
  }
  return false;
}

function main() {
  const args = resolveArgs(process.argv.slice(2));
  if (!args) return 2;

  const { mode, title, issueNumber, severity, skipIfMain } = args;

  const resolved = validatePath(args.notesPath);
  if (!resolved) return 2;

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

  const section = mode === "A" ? targetSectionForLabels(args.labels) : args.section;

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

  // Idempotency: skip silently when the entry is already recorded in the
  // target section. The key differs per mode (issue back-reference vs body).
  const present = mode === "A"
    ? entryAlreadyPresent(text, section, issueNumber)
    : bodyAlreadyPresent(text, section, title);
  if (text.length > 0 && present) {
    return 0;
  }

  const eol = detectEol(text);
  const newLine = mode === "A"
    ? `- ${title} (#${issueNumber}) <!-- promoted: #${issueNumber} -->`
    : (severity === "high" ? `- ${title} <!-- severity: high -->` : `- ${title}`);

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
