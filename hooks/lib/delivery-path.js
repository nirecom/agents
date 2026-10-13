"use strict";
// Live delivery path (#2527): what the current config says a session would
// deliver through right now. "pull_request" when worktree enforcement is on for
// this repo; "direct" when ENFORCE_WORKTREE is off, the repo is excluded, or a
// WORKTREE_OFF / WORKFLOW_OFF marker is set for the session. The recorded path
// (state delivery_path) outranks this — see workflow-state/session-profile.js.
// resolveMarkerFreeDeliveryPath is the marker-blind variant the AUTO_MERGE_PR=off
// release refusal reads (workflow-gate/release-channel-judge.js): a session marker
// must never turn a pull_request delivery into a direct one there.

const DELIVERY_PATHS = Object.freeze(["pull_request", "direct"]);

// Config only (ENFORCE_WORKTREE and the repo exclusion), no session markers.
// Fail-safe toward pull_request: an unreadable repo dir is "not excluded".
function resolveConfigDeliveryPath(repoDir) {
  const { isEnforceWorktreeOn, isRepoExcluded } = require("../enforce-worktree/config");
  if (!isEnforceWorktreeOn()) return "direct";
  if (typeof repoDir === "string" && repoDir) {
    try {
      if (isRepoExcluded(require("./branch-diff").toWindowsPath(repoDir))) return "direct";
    } catch (_) { /* not excluded */ }
  }
  return "pull_request";
}

// Requires are lazy because session-markers loads the workflow-state barrel,
// which may be mid-init here.
function resolveLiveDeliveryPath(sid, repoDir) {
  const { isEnforceWorktreeOn } = require("../enforce-worktree/config");
  const { isWorktreeOff, isWorkflowOff } = require("./session-markers");
  if (!isEnforceWorktreeOn()) return "direct";
  if (isWorktreeOff(sid) || isWorkflowOff(sid)) return "direct";
  return resolveConfigDeliveryPath(repoDir);
}

// The recorded state delivery_path when valid, else the config path; markers never read.
function resolveMarkerFreeDeliveryPath(state, repoDir) {
  const v = state && typeof state === "object" ? state.delivery_path : undefined;
  if (DELIVERY_PATHS.includes(v)) return v;
  return resolveConfigDeliveryPath(repoDir);
}

module.exports = { DELIVERY_PATHS, resolveLiveDeliveryPath, resolveConfigDeliveryPath, resolveMarkerFreeDeliveryPath };
