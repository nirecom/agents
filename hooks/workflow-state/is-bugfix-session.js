"use strict";
// SSOT for BUGFIX session detection (#1147 T0-A).
//
// Signal priority (highest first):
//   1. state.is_bugfix (immutable init-time flag set by createInitialState)
//   2. state.git_branch (fallback for states written before is_bugfix existed)
//   3. runtime branch probe (last resort; may be wrong in detached HEAD / rename)

const { execFileSync } = require("child_process");

// Returns true when branchName starts with "fix/" followed by at least one char.
// Bare "fix/" (nothing after the slash) returns false — it is not a valid branch name.
function isBugfixBranch(branchName) {
  return typeof branchName === "string" && branchName.length > 4 && branchName.startsWith("fix/");
}

// Returns true when the current session is a BUGFIX session.
// opts may be an object {repoDir, sessionId, branchName} OR a plain sessionId string.
// opts.repoDir: git repo root (used for runtime probe only).
// opts.branchName: branch name override (skips runtime probe).
function isBugfixSession(opts = {}) {
  if (typeof opts === "string") opts = { sessionId: opts };
  const { repoDir, sessionId, branchName } = opts;
  // Signal 1: session state is_bugfix flag (immutable, set at init time).
  if (sessionId) {
    try {
      const { readState } = require("./state-io");
      const state = readState(sessionId);
      if (state && typeof state.is_bugfix === "boolean") {
        return state.is_bugfix;
      }
      // Signal 2: state.git_branch fallback (old states without is_bugfix).
      if (state && typeof state.git_branch === "string") {
        return isBugfixBranch(state.git_branch);
      }
    } catch (_) {}
  }

  // Signal 3: caller-supplied branch name.
  if (typeof branchName === "string") {
    return isBugfixBranch(branchName);
  }

  // Signal 4: runtime probe (least reliable).
  if (repoDir) {
    try {
      const branch = execFileSync(
        "git", ["-C", repoDir, "rev-parse", "--abbrev-ref", "HEAD"],
        { encoding: "utf8", timeout: 3000 }
      ).trim();
      return isBugfixBranch(branch);
    } catch (_) {}
  }

  return false;
}

module.exports = { isBugfixBranch, isBugfixSession };
