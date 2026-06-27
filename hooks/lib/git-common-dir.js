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

/**
 * Returns true when dirA and dirB belong to the same git repository (i.e.
 * their git common-dirs are identical after case-insensitive, backslash-
 * normalised comparison).
 *
 * FAIL-OPEN: if either common-dir is null — because git is unavailable, the
 * directory is not inside a git repository, or any other error — the function
 * returns true. Callers MUST NOT rely on this function for security-critical
 * fail-closed enforcement; a null result means "could not confirm they differ",
 * not "confirmed same".
 *
 * Primary use case: gating resolveSessionId() Priority 7's CWD-derived JSONL
 * scan so that a foreign-repo CWD does not cause the resolver to return another
 * session's id (#1099).
 */
function isSameGitRepo(dirA, dirB) {
  const a = getGitCommonDir(dirA);
  const b = getGitCommonDir(dirB);
  if (!a || !b) return true;
  const norm = (p) => p.replace(/\\/g, "/").toLowerCase();
  return norm(a) === norm(b);
}

module.exports = { getGitCommonDir, isSameGitRepo };
