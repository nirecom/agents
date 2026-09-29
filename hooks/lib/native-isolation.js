"use strict";
// hooks/lib/native-isolation.js — predicates over the session state's
// worktree_entered_at / worktree_exited_at (recorded by
// postuse-native-worktree-record.js). Every malformed input fails open to false.

function _readWorktreeTimestamps(sessionId, readStateFn) {
  if (!sessionId) return { entered: false, exited: false };
  try {
    const state = readStateFn(sessionId);
    if (!state || typeof state !== "object") return { entered: false, exited: false };
    const enteredAt = state.worktree_entered_at;
    const exitedAt = state.worktree_exited_at;
    const entered = typeof enteredAt === "string" && enteredAt.length > 0
      && !isNaN(new Date(enteredAt).getTime());
    const exited = typeof exitedAt === "string" && exitedAt.length > 0
      && !isNaN(new Date(exitedAt).getTime());
    return { entered, exited };
  } catch (_) { return { entered: false, exited: false }; }
}

function isUnderNativeIsolation(sessionId, readStateFn) {
  const { entered, exited } = _readWorktreeTimestamps(sessionId, readStateFn);
  return entered && !exited;
}

function hasExitedWorktree(sessionId, readStateFn) {
  const { exited } = _readWorktreeTimestamps(sessionId, readStateFn);
  return exited;
}

module.exports = { isUnderNativeIsolation, hasExitedWorktree };
