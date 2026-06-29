#!/usr/bin/env node
"use strict";
// Serialize sibling-repo tuples into a JSON array, safely (#1102 security
// Finding 2 follow-up). capture-env.sh Step 2b previously built this JSON by
// hand via shell string interpolation, which corrupts when a worktree_path
// contains `"` or `\`. This reads TAB-separated tuples from stdin and lets
// JSON.stringify do the escaping.
//
// stdin: zero or more lines, each `repo\tworktree_path\tpr_number\tmerge_sha`.
//        Blank lines are ignored. Missing trailing fields default to "".
// stdout: JSON array of {repo, worktree_path, pr_number, merge_sha}.
//         Lines with an empty repo (field 0) are dropped.

const fs = require("fs");

const raw = fs.readFileSync(0, "utf8");
const out = [];
for (const line of raw.split(/\r?\n/)) {
  if (line.trim() === "") continue;
  const f = line.split("\t");
  const repo = f[0] || "";
  if (repo === "") continue;
  out.push({
    repo,
    worktree_path: f[1] || "",
    pr_number: f[2] || "",
    merge_sha: f[3] || "",
  });
}
process.stdout.write(JSON.stringify(out));
