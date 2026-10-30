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

// ---- Consumers: one parents set per commit, from the resolver or a bin/merge-parents record stream.
// A set is { state, reason, records: Map<rel, record>, noted }; state "fallback" marks a malformed stream.
const OID_FIELD = /^(-|[0-9a-f]{40}|[0-9a-f]{64})$/;
const MALFORMED = { state: "fallback", reason: "merge-parents-records-malformed" };

const parentsSet = (state, reason, map) => ({ state, reason: reason || "", records: map || new Map(), noted: false });

// loadParents(repoDir, rels) — one resolver call (looked up on module.exports, so a stub applies);
// a throw or ok:false is an undecidable set, every path then judged against HEAD only.
function loadParents(repoDir, rels) {
  let r;
  try {
    r = module.exports.resolveMergeParents(repoDir, rels);
  } catch {
    return parentsSet(MERGE_STATE.UNDECIDABLE, "merge-parents-resolver-failed");
  }
  if (!r || !r.ok) return parentsSet(MERGE_STATE.UNDECIDABLE, (r && r.reason) || "merge-parents-resolver-failed");
  const map = new Map();
  rels.forEach((rel, i) => { if (r.records[i]) map.set(rel, r.records[i]); });
  return parentsSet(r.state, r.reason, map);
}

// parseRecords(buf) — the bin/merge-parents stream as a parents set; malformed → the fallback set.
function parseRecords(buf) {
  if (buf === null || buf === undefined) return parentsSet(MALFORMED.state, MALFORMED.reason);
  const text = Buffer.isBuffer(buf) ? buf.toString("utf8") : String(buf);
  const parts = text.split("\0");
  const bad = () => parentsSet(MALFORMED.state, MALFORMED.reason);
  if (parts.length < 2 || parts.pop() !== "" || parts.length % 2 !== 1) return bad();
  const head = parts[0].split("\t");
  if (head.length < 3 || head[0] !== "state" || !["not-merging", "merging", "undecidable"].includes(head[1])) return bad();
  const map = new Map();
  for (let i = 1; i < parts.length; i += 2) {
    const f = parts[i].split("\t");
    const rel = parts[i + 1];
    if (f.length !== 5 || rel === "" || !/^[01]$/.test(f[0]) || !/^[01]$/.test(f[1])) return bad();
    if (!f.slice(2).every((o) => OID_FIELD.test(o))) return bad();
    const oid = (o) => (o === "-" ? "" : o);
    map.set(rel, rec(Number(f[0]), Number(f[1]), oid(f[2]), oid(f[3]), oid(f[4])));
  }
  const reason = head.slice(2).join("\t");
  return parentsSet(head[1], reason === "-" ? "" : reason, map);
}

// recordFor(set, rel, repoDir) — rel's record; a rel without one gets a HEAD-only record (R1-R3).
function recordFor(set, rel, repoDir) {
  if (set.records.has(rel)) return set.records.get(rel);
  const oid = (spec) => {
    const r = runGit(repoDir, ["rev-parse", "-q", "--verify", spec]);
    return r.ok ? r.stdout.trim() : "";
  };
  const h = oid(`HEAD:${rel}`);
  const s = h ? oid(`:${rel}`) : "";
  const r = h ? rec(1, s === h ? 1 : 0, h) : rec(0, 0);
  set.records.set(rel, r);
  return r;
}

// noteLine(set, { fallbackOnly }) — the one HEAD-only notice for an undecidable or malformed set, else
// null; fallbackOnly (a record file its producer already noted) notes only a malformed one.
function noteLine(set, { fallbackOnly = false } = {}) {
  if (set.noted) return null;
  if (set.state !== "fallback" && (set.state !== MERGE_STATE.UNDECIDABLE || fallbackOnly)) return null;
  set.noted = true;
  return `pre-commit: merge parents ${set.reason || "unknown"} — tests/ gates judge against HEAD only`;
}

module.exports = { resolveMergeParents, loadParents, parseRecords, recordFor, noteLine };
