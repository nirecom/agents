"use strict";
// Where did the session upstream run, and can this session go there before
// adopting (#2297)? Granularity is decided from where the downstream runs, so
// /resume-session enters a live upstream worktree first and only then adopts.

const fs = require("fs");
const { readState } = require("../../../hooks/workflow-state/state-io");
const { isMainWorktree } = require("../../../hooks/workflow-state/resolve-worktree-path");
const { toWindowsPath } = require("../../../hooks/lib/branch-diff");

const CWD_CLASSES = Object.freeze({
  LIVE_LINKED_WORKTREE: "live-linked-worktree",
  MAIN_CHECKOUT: "main-worktree",
  WORKTREE_GONE: "worktree-gone",
  CWD_UNKNOWN: "cwd-unknown",
});

const result = (classification, worktreePath) => ({ classification, worktree_path: worktreePath || null });

// classifyUpstreamCwd(upstreamSid) -> { classification, worktree_path }
// Candidates follow resolveSessionWorktreePath: state.cwd, then session_worktree
// (state.cwd stays on main when the worktree was started mid-session).
function classifyUpstreamCwd(upstreamSid) {
  let state = null;
  try {
    state = readState(upstreamSid);
  } catch (e) {
    state = null;
  }
  if (!state) return result(CWD_CLASSES.CWD_UNKNOWN);
  const candidates = [state.cwd, state.session_worktree]
    .filter((c) => typeof c === "string" && c.length > 0)
    .map(toWindowsPath);
  if (candidates.length === 0) return result(CWD_CLASSES.CWD_UNKNOWN);
  let sawMain = false;
  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) continue;
    if (!isMainWorktree(candidate)) return result(CWD_CLASSES.LIVE_LINKED_WORKTREE, candidate);
    sawMain = true;
  }
  return result(sawMain ? CWD_CLASSES.MAIN_CHECKOUT : CWD_CLASSES.WORKTREE_GONE);
}

module.exports = { CWD_CLASSES, classifyUpstreamCwd };
