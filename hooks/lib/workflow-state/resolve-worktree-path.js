"use strict";

// SSOT worktree-path resolution for the session-bound linked worktree.
//
// resolveSessionWorktreePath(sessionId) → linked-worktree path | null.
//   Resolves the worktree the current session's commit target lives in.
//   Rejects the main worktree and any unresolvable state — NEVER falls back
//   to process.cwd(). Callers that need a NOSTATE distinction must call
//   readState directly (see bin/resolve-worktree-path); this helper collapses
//   every non-resolution to null.
//
// isMainWorktree(dir) → boolean.
//   True when `dir` is the main worktree (git-dir === git-common-dir).
//   Fail-close: any error is treated as "is main worktree" (reject).

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { readState } = require("./state-io");

// True when `dir` is the main worktree (git-dir === git-common-dir).
// argv-form execFileSync (never string-template exec) so path metacharacters
// in `dir` cannot alter the command. Fail-close: any error → true (reject).
function isMainWorktree(dir) {
  try {
    const gitDir = execFileSync("git", ["-C", dir, "rev-parse", "--git-dir"], {
      encoding: "utf8",
      timeout: 5000,
    });
    const gitCommonDir = execFileSync("git", ["-C", dir, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      timeout: 5000,
    });
    return path.resolve(gitDir.trim()) === path.resolve(gitCommonDir.trim());
  } catch (_e) {
    return true;
  }
}

// Resolve the session-bound linked worktree path, or null when unresolvable.
// Fail-safe: the entire body is wrapped so any exception collapses to null.
function resolveSessionWorktreePath(sessionId) {
  try {
    let sid = sessionId;
    if (!sid) {
      sid = process.env.SESSION_ID || process.env.CLAUDE_SESSION_ID;
    }
    if (!sid) return null;
    const state = readState(sid);
    if (state === null) return null;
    if (!state.cwd || typeof state.cwd !== "string") return null;
    if (!fs.existsSync(state.cwd)) return null;
    if (isMainWorktree(state.cwd)) return null;
    return state.cwd;
  } catch (_e) {
    return null;
  }
}

module.exports = {
  isMainWorktree,
  resolveSessionWorktreePath,
};
