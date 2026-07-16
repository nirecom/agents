"use strict";
// hooks/enforce-worktree/entry-helpers.js
// Entry-point helpers for hooks/enforce-worktree.js (file-split per
// rules/coding/file-split.md Pattern A). Pure structural move — no behavior change.

const fs = require("fs");
const os = require("os");
const path = require("path");

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (e) {
    return "";
  }
}

// Resolve WORKTREE_BASE_DIR with ~ expansion and a default of ~/git/worktrees.
// Per rules/worktree.md, this is the parent directory all linked worktrees live under.
function getWorktreeBaseDirResolved() {
  const raw = (process.env.WORKTREE_BASE_DIR || "").trim();
  const baseRaw = raw || path.join(os.homedir(), "git", "worktrees");
  const expanded = baseRaw.startsWith("~")
    ? path.join(os.homedir(), baseRaw.slice(1).replace(/^[\/\\]/, ""))
    : baseRaw;
  return path.resolve(expanded);
}

module.exports = { readStdin, getWorktreeBaseDirResolved };
