"use strict";

const path = require("path");
const { spawnSync } = require("child_process");

/**
 * Returns the resolved absolute path of the git common dir for the given
 * directory, or null on failure. The common-dir path is identical for a main
 * worktree and all its linked worktrees (they all share .git/).
 */
function getGitCommonDir(dir) {
  try {
    const r = spawnSync("git", ["-C", dir, "rev-parse", "--git-common-dir"], {
      encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "pipe"],
    });
    if (r.status !== 0) return null;
    const raw = (r.stdout || "").trim();
    if (!raw) return null;
    return path.resolve(dir, raw);
  } catch (_) {
    return null;
  }
}

module.exports = { getGitCommonDir };
