"use strict";
// Live delivery path (#2527): what the current config says a session would
// deliver through right now. "pull_request" when worktree enforcement is on for
// this repo; "direct" when ENFORCE_WORKTREE is off, the repo is excluded, or a
// WORKTREE_OFF / WORKFLOW_OFF marker is set for the session. The recorded path
// (state delivery_path) outranks this — see workflow-state/session-profile.js.

const DELIVERY_PATHS = Object.freeze(["pull_request", "direct"]);

// Fail-safe toward pull_request: every reader below fails closed to "not off",
// and an unreadable repo dir is "not excluded". Requires are lazy because
// session-markers loads the workflow-state barrel, which may be mid-init here.
function resolveLiveDeliveryPath(sid, repoDir) {
  const { isEnforceWorktreeOn, isRepoExcluded } = require("../enforce-worktree/config");
  const { isWorktreeOff, isWorkflowOff } = require("./session-markers");
  if (!isEnforceWorktreeOn()) return "direct";
  if (isWorktreeOff(sid) || isWorkflowOff(sid)) return "direct";
  if (typeof repoDir === "string" && repoDir) {
    try {
      if (isRepoExcluded(require("./branch-diff").toWindowsPath(repoDir))) return "direct";
    } catch (_) { /* not excluded */ }
  }
  return "pull_request";
}

module.exports = { DELIVERY_PATHS, resolveLiveDeliveryPath };
