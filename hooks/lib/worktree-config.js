// hooks/lib/worktree-config.js
// Worktree path helpers for the parallel-session workflow.

"use strict";

const os = require("os");
const path = require("path");

/**
 * Returns the base directory for parallel-session worktrees.
 * Reads WORKTREE_BASE_DIR env var; falls back to ~/git/worktrees.
 */
function getWorktreeBaseDir() {
  return process.env.WORKTREE_BASE_DIR || path.join(os.homedir(), "git", "worktrees");
}

/**
 * Validates a task name against /^[a-zA-Z0-9_-]+$/.
 * Rejects: slashes, dots, spaces, semicolons, backticks, dollar signs, and all
 * other shell metacharacters. Throws on invalid input.
 * @param {string} name
 * @returns {string} the validated name (unchanged)
 */
function validateTaskName(name) {
  if (!name || typeof name !== "string") {
    throw new Error("task name must be a non-empty string");
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error(
      `invalid task name '${name}': only [a-zA-Z0-9_-] is allowed ` +
        "(no slashes, dots, spaces, semicolons, backticks, or other shell metacharacters)"
    );
  }
  return name;
}

/**
 * Validates a repo name (same rules as task name: [a-zA-Z0-9_-]+).
 * Throws on invalid input to prevent path traversal via repoName.
 */
function validateRepoName(name) {
  if (!name || typeof name !== "string") {
    throw new Error("repo name must be a non-empty string");
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error(
      `invalid repo name '${name}': only [a-zA-Z0-9_-] is allowed`
    );
  }
  return name;
}

/**
 * Builds the canonical worktree path: <WORKTREE_BASE_DIR>/<task-name>/<repo-name>.
 * Both taskName and repoName are validated against [a-zA-Z0-9_-]+.
 * @param {string} taskName
 * @param {string} repoName
 * @returns {string} absolute path
 */
function buildWorktreePath(taskName, repoName) {
  validateTaskName(taskName);
  validateRepoName(repoName);
  return path.join(getWorktreeBaseDir(), taskName, repoName);
}

module.exports = { getWorktreeBaseDir, validateTaskName, buildWorktreePath };
