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

function hasShellMetachar(s) {
  return /[;|&`$]/.test(s);
}

function validateSiblings(siblingWorktrees) {
  if (!Array.isArray(siblingWorktrees)) return;
  for (const entry of siblingWorktrees) {
    if (entry === null || typeof entry !== "object") {
      throw new Error("invalid sibling entry: must be a non-null object");
    }
    const repo = entry.repo;
    const worktree_path = entry.worktree_path;
    if (repo == null || repo === "") {
      throw new Error("invalid sibling entry: repo is empty or null");
    }
    if (worktree_path == null || worktree_path === "") {
      throw new Error("invalid sibling entry: worktree_path is empty or null");
    }
    if (hasNewline(repo) || hasNewline(worktree_path)) {
      throw new Error("invalid sibling entry: newline in field");
    }
    if (hasTraversal(worktree_path)) {
      throw new Error("invalid sibling entry: path traversal in worktree_path");
    }
    if (hasShellMetachar(repo) || hasShellMetachar(worktree_path)) {
      throw new Error("invalid sibling entry: shell metacharacter in field");
    }
    if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo)) {
      throw new Error("invalid sibling entry: repo must match owner/name (alphanumeric, ., -, _ only)");
    }
  }
}

function formatBaseDir(baseDir) {
  if (baseDir === undefined || baseDir === null || baseDir === "") {
    return "(default)";
  }
  return String(baseDir);
}

function buildNotesBody({ branch, createdDate, resolvedPath, mainRoot, baseDir, copiedFiles, sessionId, siblingWorktrees } = {}) {
  const normalizedMainRoot = mainRoot ? normalizePath(mainRoot) : "";
  const lines = [
    "# Worktree Notes",
    `Branch: ${branch}`,
    `Created: ${createdDate}`,
    `Path: ${resolvedPath}`,
    `Main repo: ${normalizedMainRoot}`,
    `WORKTREE_BASE_DIR: ${formatBaseDir(baseDir)}`,
  ];
  if (sessionId) {
    lines.push(`Session-ID: ${sessionId}`);
  }
  lines.push(
    "",
    "## Gitignored files copied from main",
  );

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
    "",
    "## SiblingWorktrees",
  );

  const validSiblings = [];
  if (Array.isArray(siblingWorktrees)) {
    for (const entry of siblingWorktrees) {
      if (entry == null) continue;
      const repo = entry.repo;
      const worktree_path = entry.worktree_path;
      if (repo == null || repo === "" || worktree_path == null || worktree_path === "") continue;
      if (hasNewline(repo) || hasNewline(worktree_path)) {
        throw new Error("invalid sibling entry: newline in field");
      }
      if (hasTraversal(worktree_path)) {
        throw new Error("invalid sibling entry: path traversal in worktree_path");
      }
      if (hasShellMetachar(repo) || hasShellMetachar(worktree_path)) {
        throw new Error("invalid sibling entry: shell metacharacter in field");
      }
      validSiblings.push({ repo, worktree_path });
    }
  }

  if (validSiblings.length === 0) {
    lines.push("- (none)");
  } else {
    for (const s of validSiblings) {
      lines.push(`- repo: ${s.repo}, path: ${normalizePath(s.worktree_path)}`);
    }
  }

  return lines.join("\n") + "\n";
}

function writeNotes({ worktreePath, branch, createdDate, resolvedPath, mainRoot, baseDir, copiedFiles, sessionId, siblingWorktrees }) {
  const notesPath = path.join(worktreePath, "WORKTREE_NOTES.md");
  const body = buildNotesBody({ branch, createdDate, resolvedPath, mainRoot, baseDir, copiedFiles, sessionId, siblingWorktrees });
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
    sessionId,
    siblingWorktrees,
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
  if (mainRoot && hasNewline(mainRoot)) {
    throw new Error(`Newline character in mainRoot is not allowed`);
  }
  if (sessionId != null && sessionId !== "") {
    if (typeof sessionId !== "string") {
      throw new Error(`sessionId must be a string`);
    }
    if (hasNewline(sessionId)) {
      throw new Error(`Newline character in sessionId is not allowed`);
    }
    if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
      throw new Error(`sessionId must match [a-zA-Z0-9_-]+`);
    }
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

  validateSiblings(siblingWorktrees);

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
      mainRoot,
      baseDir,
      copiedFiles,
      sessionId,
      siblingWorktrees,
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

module.exports = { buildNotesBody, writeNotes, appendExclude, run, hasTraversal, hasNewline, hasShellMetachar, validateSiblings, normalizePath };
