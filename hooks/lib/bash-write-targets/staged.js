"use strict";

const { spawnSync } = require("child_process");
const path = require("path");

/**
 * List the staged files of a git repo as repo-relative forward-slash paths.
 *
 * Uses `--diff-filter=ACM` so deletions (and other non-content changes) are
 * excluded: a deleted path has no staged content to scan, and feeding it to a
 * blob reader would fail-closed on a non-existent object.
 *
 * Returns: string[] on success (may be empty), null on spawn error / nonzero.
 */
function extractStagedFilesRelative(repoRoot) {
  if (!repoRoot || typeof repoRoot !== "string") return null;
  try {
    const r = spawnSync(
      "git", ["diff", "--cached", "--name-only", "--diff-filter=ACMR"],
      { cwd: repoRoot, encoding: "utf8", timeout: 2000 }
    );
    if (r.error || r.status !== 0) return null;
    const lines = (r.stdout || "").split("\n").filter(Boolean);
    // git already emits forward-slash paths; normalize defensively regardless.
    return lines.map((rel) => rel.split("\\").join("/"));
  } catch (e) {
    return null;
  }
}

/**
 * Get the list of staged files in a git repo as absolute paths.
 *
 * Delegates enumeration to extractStagedFilesRelative (single source of truth),
 * so the same `--diff-filter=ACM` deletion-exclusion applies here too.
 *
 * Returns: string[] on success (may be empty), null on failure.
 */
function extractStagedFiles(repoRoot) {
  const rels = extractStagedFilesRelative(repoRoot);
  if (rels === null) return null;
  return rels.map((rel) => path.resolve(repoRoot, rel));
}

module.exports = { extractStagedFiles, extractStagedFilesRelative };
