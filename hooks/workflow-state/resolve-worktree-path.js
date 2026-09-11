"use strict";

// SSOT worktree-path resolution for the session-bound linked worktree.
//
// resolveSessionWorktreePath(sessionId) → linked-worktree path | null.
//   Tries state.cwd then state.session_worktree; rejects the main worktree and
//   every unresolvable state — NEVER falls back to process.cwd(). Callers needing
//   a NOSTATE distinction call readState directly (see bin/resolve-worktree-path).
//
// isMainWorktree(dir) → boolean: true when git-dir === git-common-dir.
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
      // Lazy require: keeps the resolver out of module load and out of any future
      // require cycle through the ./workflow-state barrel.
      const { resolveSessionId } = require("./session-id");
      sid = resolveSessionId({});
    }
    if (!sid) return null;
    const state = readState(sid);
    if (state === null) return null;
    // Two candidates in order, judged by ONE predicate (CPR-E2C): a string that exists
    // and is not the main worktree. Failing it rejects the candidate, not the whole
    // resolution — state.cwd can be absent or stale while session_worktree is good.
    // session_worktree covers mid-session /worktree-start: state.cwd was recorded at
    // session creation from the main worktree, and branching-handler.js writes the real
    // linked-worktree path there after WORKFLOW_BRANCHING_COMPLETE.
    for (const candidate of [state.cwd, state.session_worktree]) {
      if (typeof candidate !== "string" || candidate === "") continue;
      if (!fs.existsSync(candidate)) continue;
      if (isMainWorktree(candidate)) continue;
      return candidate;
    }
    return null;
  } catch (_e) {
    return null;
  }
}

module.exports = {
  isMainWorktree,
  resolveSessionWorktreePath,
};
