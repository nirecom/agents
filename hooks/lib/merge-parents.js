"use strict";
// resolveMergeParents(repoDir, paths): the parent baseline(s) each staged path is judged against
// (#2812). Content only: blob oids are compared, file modes never. One record per requested path, in
// request order: { in_parent, same, b1, b2, base } ("" = absent).
//   R1 staged = H or M → existing (same=1)      R5 H = M → H alone (identical-content relief)
//   R2 neither parent → new                     R6 H != M, unique merge-base → H / M / B (3-way)
//   R3 / R4 only one parent → that blob         R7 H != M, merge-base not unique → H alone
// Outside a merge, or when the merge state is undecidable, M is treated as absent (HEAD only).
// → { ok, state, reason, records }; ok:false when the index or the HEAD tree cannot be read.

const { readMergeState, runGit, MERGE_STATE } = require("./merge-state");

// path → blob oid from `git ls-tree -r -z --full-tree <rev>`; null when the tree is unreadable.
function readTree(top, rev) {
  const r = runGit(top, ["ls-tree", "-r", "-z", "--full-tree", rev]);
  if (!r.ok) return null;
  const map = new Map();
  for (const entry of r.stdout.split("\0")) {
    const tab = entry.indexOf("\t");
    if (tab < 0) continue;
    const meta = entry.slice(0, tab).split(" ");
    if (meta[1] === "blob") map.set(entry.slice(tab + 1), meta[2]);
  }
  return map;
}

function readIndex(top) {
  const r = runGit(top, ["ls-files", "-s", "-z"]);
  if (!r.ok) return null;
  const map = new Map();
  for (const entry of r.stdout.split("\0")) {
    const tab = entry.indexOf("\t");
    if (tab < 0) continue;
    const meta = entry.slice(0, tab).split(" ");
    if (meta[2] === "0") map.set(entry.slice(tab + 1), meta[1]);
  }
  return map;
}

function readHeadTree(top) {
  const head = runGit(top, ["rev-parse", "-q", "--verify", "HEAD^{commit}"]);
  return head.ok ? readTree(top, "HEAD") : new Map();
}

// The merge-base tree when `git merge-base --all` names exactly one commit; null otherwise.
function readBaseTree(top, mergeHead) {
  const r = runGit(top, ["merge-base", "--all", "HEAD", mergeHead]);
  const bases = r.ok ? r.stdout.split(/\r?\n/).filter(Boolean) : [];
  return bases.length === 1 ? readTree(top, bases[0]) : null;
}

const rec = (inParent, same, b1, b2, base) => ({ in_parent: inParent, same, b1: b1 || "", b2: b2 || "", base: base || "" });

function resolveOne(s, h, m, baseTree, rel) {
  if (s && (s === h || s === m)) return rec(1, 1, s === h ? h : m);
  if (!h && !m) return rec(0, 0);
  if (!m) return rec(1, 0, h);
  if (!h) return rec(1, 0, m);
  if (h === m) return rec(1, 0, h);
  if (!baseTree) return rec(1, 0, h);
  return rec(1, 0, h, m, baseTree.get(rel));
}

function resolveMergeParents(repoDir, paths) {
  const tl = runGit(repoDir, ["rev-parse", "--show-toplevel"]);
  const top = tl.stdout.replace(/\r?\n$/, "");
  if (!tl.ok || top === "") return { ok: false, state: "", reason: "not-a-repo", records: [] };
  const index = readIndex(top);
  const headTree = index && readHeadTree(top);
  if (!index || !headTree) return { ok: false, state: "", reason: "tree-unreadable", records: [] };
  let ms = readMergeState(top);
  let mergeTree = null;
  if (ms.state === MERGE_STATE.MERGING) {
    mergeTree = readTree(top, ms.mergeHead);
    if (!mergeTree) ms = { state: MERGE_STATE.UNDECIDABLE, reason: "merge-head-tree-unreadable" };
  }
  const emptyMap = new Map();
  const mt = mergeTree || emptyMap;
  const needsBase = mergeTree && paths.some((p) => {
    const h = headTree.get(p);
    const m = mt.get(p);
    const s = index.get(p);
    return h && m && h !== m && s !== h && s !== m;
  });
  const baseTree = needsBase ? readBaseTree(top, ms.mergeHead) : null;
  const records = paths.map((p) => resolveOne(index.get(p), headTree.get(p), mt.get(p), baseTree, p));
  return { ok: true, state: ms.state, reason: ms.reason || "", records };
}

module.exports = { resolveMergeParents };
