"use strict";
// Tests: hooks/lib/merge-parents.js
// Tags: TL2, hooks, merge, merge-parents, worktree, scope:issue-specific
// Private cases of tests/hooks/feat-2812-merge-parents.js: a merge left in progress inside a linked
// worktree, where `git rev-parse --git-path MERGE_HEAD` names the per-worktree gitdir
// (<main>/.git/worktrees/<name>/MERGE_HEAD) and the main checkout has no MERGE_HEAD at all.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const X = require("./fixture");

const { check, oid, norm, show } = X;

// A fixture repo plus a linked worktree on its own branch, with the merge started in the worktree.
function linkedMerge(tag) {
  const main = X.mkRepo(tag, { "a.txt": "a\n" });
  const wt = X.slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), `mp2812-${tag}-wt-`)), "wt"));
  X.git(main, ["worktree", "add", "-q", "-b", `wt-${tag}`, wt]);
  const fx = X.M.startMerge(wt, {
    upstream: { "r4.txt": "m4\n", "in.txt": "in\n" },
    branch: { "a.txt": "a2\n" },
    resolve: { "r4.txt": "m4 edited in the merge\n" },
  });
  const gitPath = X.git(wt, ["rev-parse", "--git-path", "MERGE_HEAD"]).stdout.trim();
  const mainHas = fs.existsSync(path.join(main, ".git", "MERGE_HEAD"));
  check(`${tag} precondition: MERGE_HEAD lives in the per-worktree gitdir`, /worktrees\//.test(X.slash(gitPath)) && !mainHas,
    `git-path=${gitPath} main-has-MERGE_HEAD=${mainHas}`);
  return Object.assign({ main, wt }, fx);
}

const C = {};
C.worktreeR4 = () => {
  const fx = linkedMerge("wt-r4");
  const paths = ["r4.txt", "in.txt", "a.txt"];
  const r = X.resolve("worktree R4", fx.wt, paths);
  if (!r) return;
  check("worktree: ok and merging", r.ok === true && r.state === "merging", show(r));
  const recs = Array.isArray(r.records) && r.records.length === paths.length ? r.records.map(norm) : null;
  const want = [
    { in_parent: 1, same: 0, b1: oid(fx.wt, "MERGE_HEAD:r4.txt"), b2: "", base: "" },
    { in_parent: 1, same: 1, b1: oid(fx.wt, "MERGE_HEAD:in.txt"), b2: "", base: "" },
    { in_parent: 1, same: 1, b1: oid(fx.wt, "HEAD:a.txt"), b2: "", base: "" },
  ];
  paths.forEach((p, i) => check(`worktree: ${p} -> ${show(want[i])}`, !!recs && show(recs[i]) === show(want[i]), `${show(recs && recs[i])} full=${show(r)}`));
};

C.worktreeDetect = () => {
  const fx = linkedMerge("wt-detect");
  const m = X.mod("worktree detect", "hooks/lib/merge-incoming.js");
  if (!m) return;
  const r = m.detectMergeIncoming(fx.wt, ["r4.txt", "in.txt", "a.txt"]);
  check("worktree detect: merging with the worktree's MERGE_HEAD", !!r && r.state === "merging" && r.mergeHead === fx.mergeHead,
    JSON.stringify(r, (k, v) => (v instanceof Set ? [...v] : v)));
  check("worktree detect: only the unchanged in.txt is incoming", !!r && r.paths instanceof Set && [...r.paths].sort().join(",") === "in.txt",
    JSON.stringify(r, (k, v) => (v instanceof Set ? [...v] : v)));
};

module.exports = C;
