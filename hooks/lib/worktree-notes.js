#!/usr/bin/env node
// Core logic for generating WORKTREE_NOTES.md and registering it in
// .git/info/exclude. Consumed by bin/worktree-write-notes.js and unit-tested
// via tests/feature-worktree-write-notes.sh.

"use strict";

const fs = require("fs");
const path = require("path");

function normalizePath(p) {
  return String(p).replace(/\\/g, "/");
}

function hasTraversal(p) {
  return normalizePath(p).split("/").includes("..");
}

function hasNewline(s) {
  return typeof s === "string" && (s.includes("\n") || s.includes("\r"));
}

function formatBaseDir(baseDir) {
  if (baseDir === undefined || baseDir === null || baseDir === "") {
    return "(default)";
  }
  return String(baseDir);
}

function buildNotesBody({ branch, createdDate, resolvedPath, baseDir, copiedFiles } = {}) {
  const lines = [
    "# Worktree Notes",
    `Branch: ${branch}`,
    `Created: ${createdDate}`,
    `Path: ${resolvedPath}`,
    `WORKTREE_BASE_DIR: ${formatBaseDir(baseDir)}`,
    "",
    "## Gitignored files copied from main",
  ];

  if (!Array.isArray(copiedFiles) || copiedFiles.length === 0) {
    lines.push("- (none)");
  } else {
    for (const f of copiedFiles) {
      lines.push(`- ${f}`);
    }
  }

  lines.push(
    "",
    "## BugsFound",
    "- (none)",
    "",
    "## RelatedTasks",
    "- (none)",
    "",
    "## NextTasks",
    "- (none)",
    "",
    "## History Notes",
    "- (none)",
    "",
    "## Changelog Notes",
    "- (none)",
  );

  return lines.join("\n") + "\n";
}

function writeNotes({ worktreePath, branch, createdDate, resolvedPath, baseDir, copiedFiles }) {
  const notesPath = path.join(worktreePath, "WORKTREE_NOTES.md");
  const body = buildNotesBody({ branch, createdDate, resolvedPath, baseDir, copiedFiles });
  fs.writeFileSync(notesPath, body, { encoding: "utf8" });
  return { notesPath, notesWritten: true };
}

/**
 * Append a pattern to <mainRoot>/.git/info/exclude.
 *
 * IMPORTANT: `mainRoot` MUST be the **main repository root** (the directory
 * containing `.git/` as a real directory). It must NOT be a linked worktree
 * root, where `.git` is a file pointing back at the main repo. Callers are
 * responsible for resolving the main worktree path before invoking this
 * function.
 */
function appendExclude({ mainRoot, pattern }) {
  const gitPath = path.join(mainRoot, ".git");

  let gitStat;
  try {
    gitStat = fs.lstatSync(gitPath);
  } catch (e) {
    if (e.code === "ENOENT") {
      throw new Error(`no .git directory at ${mainRoot}`);
    }
    throw e;
  }

  if (gitStat.isSymbolicLink()) {
    throw new Error(
      `unexpected: ${gitPath} is a symlink, expected main repo root ` +
        "(linked worktree paths are not supported by appendExclude; resolve the main worktree first)"
    );
  }

  if (!gitStat.isDirectory()) {
    throw new Error(
      `unexpected: ${gitPath} is a file, expected main repo root ` +
        "(linked worktree paths are not supported by appendExclude; resolve the main worktree first)"
    );
  }

  const infoDir = path.join(mainRoot, ".git", "info");
  const excludePath = path.join(infoDir, "exclude");
  fs.mkdirSync(infoDir, { recursive: true });

  let existing = "";
  try {
    existing = fs.readFileSync(excludePath, "utf8");
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }

  if (hasNewline(pattern)) {
    throw new Error(`Newline character in pattern would corrupt exclude file`);
  }

  const lines = existing.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === pattern) {
      return { excludePath, excludeAdded: false, excludeSkipReason: "already-present" };
    }
  }

  let next = existing;
  if (next.length > 0 && !next.endsWith("\n")) {
    next += "\n";
  }
  next += pattern + "\n";
  fs.writeFileSync(excludePath, next, { encoding: "utf8" });
  return { excludePath, excludeAdded: true, excludeSkipReason: null };
}

function run(input) {
  const {
    mainRoot,
    worktreePath,
    branch,
    createdDate,
    resolvedPath,
    baseDir,
    copiedFiles,
    excludePattern,
  } = input;

  if (hasTraversal(mainRoot)) {
    throw new Error(`Path traversal detected in mainRoot: ${mainRoot}`);
  }
  if (hasTraversal(worktreePath)) {
    throw new Error(`Path traversal detected in worktreePath: ${worktreePath}`);
  }
  if (resolvedPath && hasTraversal(resolvedPath)) {
    throw new Error(`Path traversal detected in resolvedPath: ${resolvedPath}`);
  }
  if (excludePattern && hasTraversal(excludePattern)) {
    throw new Error(`Path traversal detected in excludePattern: ${excludePattern}`);
  }
  if (excludePattern && hasNewline(excludePattern)) {
    throw new Error(`Newline character in excludePattern is not allowed`);
  }
  if (branch && hasNewline(branch)) {
    throw new Error(`Newline character in branch is not allowed`);
  }
  if (createdDate && hasNewline(createdDate)) {
    throw new Error(`Newline character in createdDate is not allowed`);
  }
  if (resolvedPath && hasNewline(resolvedPath)) {
    throw new Error(`Newline character in resolvedPath is not allowed`);
  }
  if (baseDir != null && hasNewline(String(baseDir))) {
    throw new Error(`Newline character in baseDir is not allowed`);
  }
  if (Array.isArray(copiedFiles)) {
    for (const f of copiedFiles) {
      if (typeof f !== "string") {
        throw new Error(`copiedFiles entries must be strings; got ${typeof f}`);
      }
      if (hasTraversal(f)) {
        throw new Error(`Path traversal detected in copiedFiles entry: ${f}`);
      }
      if (hasNewline(f)) {
        throw new Error(`Newline character in copiedFiles entry is not allowed: ${f}`);
      }
    }
  }

  const result = {
    notesPath: null,
    notesWritten: false,
    excludePath: null,
    excludeAdded: false,
    excludeSkipReason: null,
    errors: [],
  };

  try {
    const w = writeNotes({
      worktreePath,
      branch,
      createdDate,
      resolvedPath: resolvedPath || worktreePath,
      baseDir,
      copiedFiles,
    });
    result.notesPath = w.notesPath;
    result.notesWritten = true;
  } catch (e) {
    result.errors.push(`writeNotes failed: ${e.message}`);
    result.notesWritten = false;
  }

  try {
    const a = appendExclude({ mainRoot, pattern: excludePattern || "WORKTREE_NOTES.md" });
    result.excludePath = a.excludePath;
    result.excludeAdded = a.excludeAdded;
    result.excludeSkipReason = a.excludeSkipReason;
  } catch (e) {
    result.errors.push(`appendExclude failed: ${e.message}`);
    result.excludeAdded = false;
    result.excludeSkipReason = e.message;
  }

  return result;
}

module.exports = { buildNotesBody, writeNotes, appendExclude, run, hasTraversal, normalizePath };
