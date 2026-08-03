"use strict";

const { isExcluded } = require("../shared-cmd-utils");
const { isGhWriteIR } = require("../../lib/bash-write-patterns");
const { parse } = require("../../lib/command-ir");
const { extractStagedFiles } = require("../../lib/bash-write-targets");

// EXCLUDE check for file-target writes and git commit (staged files).
function isWriteTargetAllExcluded(cmd, targets, repoRoot, patterns) {
  if (!patterns || patterns.length === 0) return false;
  const isGitCommit = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*commit\b/.test(cmd);

  if (isGitCommit) {
    const staged = extractStagedFiles(repoRoot);
    if (staged === null || staged.length === 0) return false;
    if (!staged.every((f) => isExcluded(f, patterns))) return false;
  }

  // File-target EXCLUDE check applies only to file-path ("ancestor") targets.
  // A git self-target ({resolveVia:"self", path:repoRoot}) is a repo root, not a
  // file — it is NEVER covered by a file-path EXCLUDE glob, so including it here
  // would wrongly fail the staged-file EXCLUDE exception for `git commit` (the
  // git self-target was merged into `targets` post-#1401). The self-target's
  // exclusion is governed by the staged-file check above, not by file globs.
  const fileTargets = targets ? targets.filter((t) => t.resolveVia !== "self") : null;
  if (fileTargets && fileTargets.length > 0) {
    if (!fileTargets.every((f) => isExcluded(f.path, patterns))) return false;
  }

  return isGitCommit || (fileTargets !== null && fileTargets.length > 0);
}

// True if cmd/ir is a Group B gh write. Accepts IR object or raw string (backward compat).
function isGhWriteCommand(ir) {
  if (typeof ir === "string") ir = parse(ir);
  return isGhWriteIR(ir);
}

module.exports = {
  isWriteTargetAllExcluded,
  isGhWriteCommand,
};
