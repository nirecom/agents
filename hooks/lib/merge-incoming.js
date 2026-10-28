"use strict";
// detectMergeIncoming(repoDir, stagedPaths): which staged paths are merge-incoming files — paths whose
// index state (blob and mode, or absence) equals MERGE_HEAD's. Returns one of three states and never
// throws: not-merging | merging { mergeHead, paths ⊆ stagedPaths } | undecidable { reason }.
// The merge state itself comes from merge-state.js (readMergeState); git inherits GIT_DIR /
// GIT_INDEX_FILE, so the temporary index of a `git commit <paths>` pre-commit (#2507) is compared.

const { readMergeState, runGit, MERGE_STATE, undecidable } = require("./merge-state");

const MERGE_INCOMING_STATE = MERGE_STATE;

function detect(repoDir, stagedPaths) {
  if (typeof repoDir !== "string" || repoDir === "" || !Array.isArray(stagedPaths)) return undecidable("invalid-argument");
  const ms = readMergeState(repoDir);
  if (ms.state !== MERGE_STATE.MERGING) return ms;
  const mergeHead = ms.mergeHead;
  // --ignore-submodules=none: a user's diff.ignoreSubmodules must not hide a changed gitlink.
  const diff = runGit(repoDir, ["diff", "--cached", "--name-only", "-z", "--no-renames", "--ignore-submodules=none", mergeHead]);
  if (!diff.ok) return undecidable("diff-failed");
  const differing = new Set(diff.stdout.split("\0").filter(Boolean));
  return { state: MERGE_STATE.MERGING, mergeHead, paths: new Set(stagedPaths.filter((p) => !differing.has(p))) };
}

function detectMergeIncoming(repoDir, stagedPaths) {
  try {
    return detect(repoDir, stagedPaths);
  } catch {
    return undecidable("exception");
  }
}

module.exports = { detectMergeIncoming, MERGE_INCOMING_STATE };
