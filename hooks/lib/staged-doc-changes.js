"use strict";

// Narrow staged-doc predicate: is any Markdown file (*.md, at any depth) present
// in the git index for `repoDir`? The `-- '*.md'` pathspec is a git glob that
// matches .md at the repo root and under any directory, and excludes every
// non-.md path — so a staged docs/foo/bar.ts is not a doc change.
//
// CPR-NRS: a broader hasStagedDocChanges lives in hooks/workflow-gate/
// staged-evidence.js (it also treats any docs/ path and an external docs repo as
// doc changes). This one is intentionally the *.md-only class, the predicate the
// review_docs skip guard needs; the two are not interchangeable.

const { spawnSync } = require("child_process");

function hasStagedDocChanges(repoDir) {
  const res = spawnSync(
    "git",
    ["diff", "--cached", "--name-only", "--diff-filter=ACMRT", "--", "*.md"],
    { cwd: repoDir, encoding: "utf8" }
  );
  if (res.error || res.status !== 0) return false;
  return String(res.stdout || "").trim().length > 0;
}

module.exports = { hasStagedDocChanges };
