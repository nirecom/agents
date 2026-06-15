"use strict";

const { spawnSync } = require("child_process");
const path = require("path");

/**
 * Get the list of staged files in a git repo as absolute paths.
 *
 * Returns: string[] on success (may be empty), null on failure.
 */
function extractStagedFiles(repoRoot) {
  if (!repoRoot || typeof repoRoot !== "string") return null;
  try {
    const r = spawnSync(
      "git", ["diff", "--cached", "--name-only"],
      { cwd: repoRoot, encoding: "utf8", timeout: 2000 }
    );
    if (r.status !== 0) return null;
    const lines = (r.stdout || "").split("\n").filter(Boolean);
    return lines.map((rel) => path.resolve(repoRoot, rel));
  } catch (e) {
    return null;
  }
}

module.exports = { extractStagedFiles };
