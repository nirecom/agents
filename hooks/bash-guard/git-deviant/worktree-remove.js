"use strict";
// hooks/bash-guard/git-deviant/worktree-remove.js — `git worktree remove` argv -> form id, or null.

const { scanOptions, hasLong } = require("./options");

const WORKTREE_REMOVE_SPEC = Object.freeze({
  shortWithValue: new Set(),
  longWithValue: new Set(),
  longNames: ["force"],
});

/** @param {string[]} args the argv after `worktree remove` @returns {string|null} */
function judgeWorktreeRemove(args) {
  const scan = scanOptions(args, WORKTREE_REMOVE_SPEC);
  return scan.shortFlags.has("f") || hasLong(scan, "force") ? "worktree-remove-force" : null;
}

module.exports = { judgeWorktreeRemove };
