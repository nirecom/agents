"use strict";
// Baseline resolution of the comment-block review (#2507): what a staged path looked like before
// the change — HEAD first, then the refs of an in-progress merge / cherry-pick / revert / rebase.

const fs = require("fs");
const path = require("path");

const MAX_MERGE_HEADS = 8;
const IN_PROGRESS = [["CHERRY_PICK_HEAD", "cherry-pick"], ["REVERT_HEAD", "revert"], ["REBASE_HEAD", "rebase"]];

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

// inProgress(git, cwd) -> { label, refs }; git(args) -> { ok, out }.
function inProgress(git, cwd) {
  const out = { label: "", refs: [] };
  const gd = git(["rev-parse", "--git-dir"]);
  const gitDir = gd.ok ? gd.out.toString("utf8").replace(/\r?\n$/, "") : "";
  if (!gitDir) return out;
  const dir = path.resolve(cwd, gitDir);
  const isCommit = (ref) => git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]).ok;
  const merge = readText(path.join(dir, "MERGE_HEAD"));
  if (merge !== null) {
    out.label = "merge";
    const heads = merge.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l !== "");
    for (const line of heads) {
      if (out.refs.length >= MAX_MERGE_HEADS) break;
      if (isCommit(line)) out.refs.push(line);
    }
  }
  for (const [name, label] of IN_PROGRESS) {
    const text = readText(path.join(dir, name));
    if (text === null) continue;
    if (!out.label) out.label = label;
    const sha = text.split("\n")[0].replace(/[\r\n]/g, "");
    if (sha && isCommit(sha)) out.refs.push(sha);
  }
  return out;
}

// treeOids(git, ref) -> Map path -> object id of every non-tree entry of <ref>; throws on a git failure.
function treeOids(git, ref) {
  const r = git(["ls-tree", "-r", "-z", "--full-tree", ref]);
  if (!r.ok) throw new Error(`git ls-tree ${ref} failed (rc=${r.status})`);
  const map = new Map();
  for (const rec of r.out.toString("utf8").split("\0")) {
    const tab = rec.indexOf("\t");
    if (tab >= 0) map.set(rec.slice(tab + 1), rec.slice(0, tab).split(" ")[2]);
  }
  return map;
}

// findBaselines(git, headOk, refs, srcs) -> Map src -> baseline object id, HEAD first, then each ref;
// one tree listing per ref, taken only while a src is unresolved. A tree lookup, not an object
// lookup: a listed path whose blob is missing stays "exists but unreadable", never "no baseline".
function findBaselines(git, headOk, refs, srcs) {
  const out = new Map();
  let left = [...new Set(srcs)];
  for (const ref of headOk ? ["HEAD", ...refs] : refs) {
    if (left.length === 0) break;
    const tree = treeOids(git, ref);
    for (const src of left) if (tree.has(src)) out.set(src, tree.get(src));
    left = left.filter((src) => !out.has(src));
  }
  return out;
}

module.exports = { inProgress, findBaselines };
