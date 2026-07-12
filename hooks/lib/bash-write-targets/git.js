"use strict";

// hooks/lib/bash-write-targets/git.js
// git write self-target extractor (#1401, C1).
//
// git writes target repository state (object store / refs / working tree), not a
// file path — so their scope target IS the repoRoot itself, tagged
// {resolveVia:"self"} so the scope helper uses it directly (no findRepoRoot).

const { isGitWriteIR } = require("../bash-write-patterns/patterns");

/**
 * @param {import('../command-ir').IR} ir  Parsed command IR.
 * @param {string|null|undefined} repoRoot  Resolved repo root for the command's CWD.
 * @returns {Array<{resolveVia:"self",path:string}>|null|[]}
 *   - []   when not a git write (no git target contribution).
 *   - [{resolveVia:"self", path: repoRoot}] when a git write and repoRoot is a non-empty string.
 *   - null when a git write but repoRoot is null/empty (fail-closed: a git write
 *     whose repoRoot cannot be resolved must not be silently allowed).
 */
function extractGitWriteTargets(ir, repoRoot) {
  if (!isGitWriteIR(ir)) return [];
  if (typeof repoRoot !== "string" || repoRoot === "") return null; // fail-closed
  return [{ resolveVia: "self", path: repoRoot }];
}

module.exports = { extractGitWriteTargets };
