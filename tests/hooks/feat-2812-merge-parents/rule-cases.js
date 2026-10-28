"use strict";
// Tests: hooks/lib/merge-parents.js
// Tags: TL2, hooks, merge, merge-parents, scope:issue-specific
// Private cases of tests/hooks/feat-2812-merge-parents.js: resolveMergeParents(repoDir, paths) on real
// fixture repos — rules R1-R7, the identical-content relief (R5 with and without a merge-base blob,
// R5 inside a criss-cross), the lazy merge-base read, mode-only differences, HEAD-only fallbacks
// (octopus, unreadable MERGE_HEAD tree, not merging), GIT_INDEX_FILE and the ok:false path.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const X = require("./fixture");

const { check, oid, norm, show } = X;

// The record of rel in r (records follow the request order of paths).
function recOf(r, paths, rel) {
  if (!r || !Array.isArray(r.records) || r.records.length !== paths.length) return null;
  return norm(r.records[paths.indexOf(rel)]);
}
function expectRec(label, r, paths, rel, want) {
  const got = recOf(r, paths, rel);
  return check(`${label}: ${rel} -> ${show(want)}`, !!got && show(got) === show(want), `${show(got)} full=${show(r)}`);
}

let shared;
// One allRules merge for R1-R6 (built once; each rule is its own case below).
function rules(label) {
  if (!shared) {
    const fx = X.allRules("rules");
    const paths = ["r1h.txt", "r1m.txt", "r2.txt", "r3.txt", "r4.txt", "r5.txt", "r5nb.txt", "r6.txt", "r6nb.txt", "mode.sh"];
    const t = X.traced(() => X.resolve(label, fx.repo, paths));
    shared = { repo: fx.repo, paths, r: t.value, trace: t.trace };
  }
  if (!shared.r) {
    check(`${label}: resolveMergeParents returned a result`, false, "no result (see the first rule case)");
    return null;
  }
  check(`${label}: ok and merging`, shared.r.ok === true && shared.r.state === "merging", show(shared.r));
  return shared;
}

// Case bodies by label; the entrypoint wraps each in its caseBegin/caseEnd markers.
const C = {};
C.R1 = () => {
  const s = rules("R1");
  if (!s) return;
  expectRec("R1 equal to HEAD", s.r, s.paths, "r1h.txt", { in_parent: 1, same: 1, b1: oid(s.repo, "HEAD:r1h.txt"), b2: "", base: "" });
  expectRec("R1 equal to MERGE_HEAD only", s.r, s.paths, "r1m.txt", { in_parent: 1, same: 1, b1: oid(s.repo, "MERGE_HEAD:r1m.txt"), b2: "", base: "" });
  check("R1 precondition: r1m.txt is absent from HEAD", oid(s.repo, "HEAD:r1m.txt") === "", "present");
};

// R1 on a path both parents carry with different blobs: the staged blob equals one side exactly.
C.R1shared = () => {
  for (const side of ["HEAD", "MERGE_HEAD"]) {
    const body = side === "HEAD" ? "h\n" : "m\n";
    const repo = X.mkRepo(`r1s-${side}`, { "s.txt": "base\n" });
    X.M.startMerge(repo, { upstream: { "s.txt": "m\n" }, branch: { "s.txt": "h\n" }, resolve: { "s.txt": body } });
    check(`R1 shared ${side} precondition: parents differ`, oid(repo, "HEAD:s.txt") !== oid(repo, "MERGE_HEAD:s.txt"), "same blob");
    const r = X.resolve(`R1 shared ${side}`, repo, ["s.txt"]);
    expectRec(`R1 shared, staged equal to ${side}`, r, ["s.txt"], "s.txt", { in_parent: 1, same: 1, b1: oid(repo, `${side}:s.txt`), b2: "", base: "" });
  }
};

C.R2 = () => {
  const s = rules("R2");
  if (s) expectRec("R2", s.r, s.paths, "r2.txt", { in_parent: 0, same: 0, b1: "", b2: "", base: "" });
};

C.R3 = () => {
  const s = rules("R3");
  if (s) expectRec("R3", s.r, s.paths, "r3.txt", { in_parent: 1, same: 0, b1: oid(s.repo, "HEAD:r3.txt"), b2: "", base: "" });
};

C.R4 = () => {
  const s = rules("R4");
  if (s) expectRec("R4", s.r, s.paths, "r4.txt", { in_parent: 1, same: 0, b1: oid(s.repo, "MERGE_HEAD:r4.txt"), b2: "", base: "" });
};

C.R5 = () => {
  const s = rules("R5");
  if (!s) return;
  check("R5 precondition: r5.txt has a merge-base blob, r5nb.txt has none",
    oid(s.repo, `${X.mergeBase(s.repo)[0]}:r5.txt`) !== "" && oid(s.repo, `${X.mergeBase(s.repo)[0]}:r5nb.txt`) === "", X.mergeBase(s.repo).join(","));
  expectRec("R5 base present", s.r, s.paths, "r5.txt", { in_parent: 1, same: 0, b1: oid(s.repo, "HEAD:r5.txt"), b2: "", base: "" });
  expectRec("R5 base absent", s.r, s.paths, "r5nb.txt", { in_parent: 1, same: 0, b1: oid(s.repo, "HEAD:r5nb.txt"), b2: "", base: "" });
};

C.R6 = () => {
  const s = rules("R6");
  if (!s) return;
  const mb = X.mergeBase(s.repo);
  check("R6 precondition: exactly one merge-base", mb.length === 1, mb.join(","));
  expectRec("R6 base present", s.r, s.paths, "r6.txt",
    { in_parent: 1, same: 0, b1: oid(s.repo, "HEAD:r6.txt"), b2: oid(s.repo, "MERGE_HEAD:r6.txt"), base: oid(s.repo, `${mb[0]}:r6.txt`) });
  expectRec("R6 base absent (add/add)", s.r, s.paths, "r6nb.txt",
    { in_parent: 1, same: 0, b1: oid(s.repo, "HEAD:r6nb.txt"), b2: oid(s.repo, "MERGE_HEAD:r6nb.txt"), base: "" });
  check("R6 positive control: GIT_TRACE recorded git merge-base for an H != M path", X.ranMergeBase(s.trace), s.trace.slice(0, 400) || "(empty trace)");
};

C.R7 = () => {
  const repo = X.crissCross("r7");
  check("R7 precondition: two merge-bases", X.mergeBase(repo).length === 2, X.mergeBase(repo).join(","));
  const paths = ["cc-diff.txt", "cc-same.txt"];
  const r = X.resolve("R7", repo, paths);
  if (!r) return;
  check("R7 ok and merging", r.ok === true && r.state === "merging", show(r));
  expectRec("R7 H != M", r, paths, "cc-diff.txt", { in_parent: 1, same: 0, b1: oid(repo, "HEAD:cc-diff.txt"), b2: "", base: "" });
  expectRec("R7 H = M in a criss-cross", r, paths, "cc-same.txt", { in_parent: 1, same: 0, b1: oid(repo, "HEAD:cc-same.txt"), b2: "", base: "" });
};

C.lazy = () => {
  const repo = X.identicalOnly("lazy");
  const paths = ["same.txt", "nb.txt", "up.txt", "keep.txt"];
  const t = X.traced(() => X.resolve("lazy-merge-base", repo, paths));
  if (!t.value) return;
  check("lazy-merge-base: the trace file was written (GIT_TRACE reached git)", /trace|git/.test(t.trace), "(empty trace)");
  check("lazy-merge-base: git merge-base did not run", !X.ranMergeBase(t.trace), t.trace.split(/\r?\n/).filter((l) => /merge-base/.test(l)).join(" | "));
  expectRec("lazy-merge-base", t.value, paths, "same.txt", { in_parent: 1, same: 0, b1: oid(repo, "HEAD:same.txt"), b2: "", base: "" });
};

C.mode = () => {
  const s = rules("mode");
  if (!s) return;
  const staged = X.git(s.repo, ["ls-files", "-s", "--", "mode.sh"]).stdout;
  check("mode precondition: mode.sh is staged 100755", /^100755 /.test(staged), staged);
  expectRec("mode", s.r, s.paths, "mode.sh", { in_parent: 1, same: 1, b1: oid(s.repo, "HEAD:mode.sh"), b2: "", base: "" });
};

C.fallback = () => {
  const oct = X.mkRepo("oct");
  const fx = X.M.octopusMerge(oct, "word");
  check("fallback precondition: octopus MERGE_HEAD has two lines", fx.lines.length === 2, fx.lines.join("|"));
  const op = ["docs/main-only.md", "README.md"];
  const r = X.resolve("fallback octopus", oct, op);
  if (r) {
    check("fallback octopus: ok, undecidable / octopus", r.ok === true && r.state === "undecidable" && r.reason === "octopus", show(r));
    expectRec("fallback octopus", r, op, "docs/main-only.md", { in_parent: 0, same: 0, b1: "", b2: "", base: "" });
    expectRec("fallback octopus", r, op, "README.md", { in_parent: 1, same: 1, b1: oid(oct, "HEAD:README.md"), b2: "", base: "" });
  }
  const bad = X.mkRepo("bad", { "docs/shared.md": "# s\n" });
  X.M.startMerge(bad, { upstream: { "docs/incoming.md": "# in\n" }, branch: { "docs/shared.md": "# s2\n" } });
  X.M.corruptMergeHead(bad);
  const bp = ["docs/incoming.md"];
  const b = X.resolve("fallback corrupt", bad, bp);
  if (b) {
    check("fallback corrupt: ok, undecidable / merge-head-tree-unreadable", b.ok === true && b.state === "undecidable" && b.reason === "merge-head-tree-unreadable", show(b));
    expectRec("fallback corrupt", b, bp, "docs/incoming.md", { in_parent: 0, same: 0, b1: "", b2: "", base: "" });
  }
};

C.notMerging = () => {
  const repo = X.mkRepo("plain", { "f.txt": "f\n" });
  X.M.apply(repo, { "f.txt": "f edited\n", "new.txt": "new\n" });
  const paths = ["new.txt", "f.txt", "README.md"];
  const r = X.resolve("not-merging", repo, paths);
  if (!r) return;
  check("not-merging: ok, state not-merging", r.ok === true && r.state === "not-merging", show(r));
  expectRec("not-merging", r, paths, "new.txt", { in_parent: 0, same: 0, b1: "", b2: "", base: "" });
  expectRec("not-merging", r, paths, "f.txt", { in_parent: 1, same: 0, b1: oid(repo, "HEAD:f.txt"), b2: "", base: "" });
  expectRec("not-merging", r, paths, "README.md", { in_parent: 1, same: 1, b1: oid(repo, "HEAD:README.md"), b2: "", base: "" });
};

C.indexFile = () => {
  const repo = X.mkRepo("idx", { "f.txt": "f\n" });
  const alt = X.slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-idx-")), "alt-index"));
  fs.copyFileSync(path.join(repo, ".git", "index"), alt);
  X.M.apply(repo, { "f.txt": "f edited\n" });
  const saved = process.env.GIT_INDEX_FILE;
  process.env.GIT_INDEX_FILE = alt;
  let r;
  try {
    r = X.resolve("index-file", repo, ["f.txt"]);
  } finally {
    if (saved === undefined) delete process.env.GIT_INDEX_FILE;
    else process.env.GIT_INDEX_FILE = saved;
  }
  if (!r) return;
  expectRec("index-file alternate index (equal to HEAD)", r, ["f.txt"], "f.txt", { in_parent: 1, same: 1, b1: oid(repo, "HEAD:f.txt"), b2: "", base: "" });
  const d = X.resolve("index-file default", repo, ["f.txt"]);
  expectRec("index-file default index (edited)", d, ["f.txt"], "f.txt", { in_parent: 1, same: 0, b1: oid(repo, "HEAD:f.txt"), b2: "", base: "" });
};

C.okFalse = () => {
  const notRepo = X.slash(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-norepo-")));
  if (!check("ok-false precondition: the temp dir is outside any repo", X.git(notRepo, ["rev-parse", "--git-dir"], true).status !== 0, notRepo)) return;
  const r = X.resolve("ok-false", notRepo, ["a.txt"]);
  if (r) check("ok-false: a directory outside any repo gives ok:false", r.ok === false, show(r));
};

// An index git cannot parse, and a HEAD whose tree object is gone: ok:false / tree-unreadable, and the
// CLI exits 2 naming the reason (bin/lib/merge-parents.sh then falls back to HEAD only).
C.treeUnreadable = () => {
  const repo = X.mkRepo("unreadable-idx", { "f.txt": "f\n" });
  const bad = X.slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-badidx-")), "index"));
  fs.writeFileSync(bad, "not a git index\n");
  const saved = process.env.GIT_INDEX_FILE;
  process.env.GIT_INDEX_FILE = bad;
  let r;
  try {
    r = X.resolve("unreadable index", repo, ["f.txt"]);
  } finally {
    if (saved === undefined) delete process.env.GIT_INDEX_FILE;
    else process.env.GIT_INDEX_FILE = saved;
  }
  if (r) check("unreadable index: ok:false, tree-unreadable, no records", r.ok === false && r.reason === "tree-unreadable" && r.records.length === 0, show(r));
  const ci = X.cli(["--repo", repo], ["f.txt"], { GIT_INDEX_FILE: bad });
  check("unreadable index: CLI exits 2", ci.code === 2, `exit=${ci.code} ${ci.err}`);
  check("unreadable index: CLI stderr names tree-unreadable", ci.err.includes("cannot resolve parents (tree-unreadable)"), ci.err);
  check("unreadable index: CLI writes no record stream", ci.out === "", JSON.stringify(ci.out));

  const head = X.mkRepo("unreadable-head", { "f.txt": "f\n" });
  const tree = oid(head, "HEAD^{tree}");
  const loose = path.join(head, ".git", "objects", tree.slice(0, 2), tree.slice(2));
  if (!check("unreadable HEAD precondition: the HEAD tree is a loose object", fs.existsSync(loose), loose)) return;
  fs.chmodSync(loose, 0o644);
  fs.unlinkSync(loose);
  check("unreadable HEAD precondition: HEAD still names a commit", X.git(head, ["rev-parse", "-q", "--verify", "HEAD^{commit}"], true).status === 0, head);
  const h = X.resolve("unreadable HEAD tree", head, ["f.txt"]);
  if (h) check("unreadable HEAD tree: ok:false, tree-unreadable", h.ok === false && h.reason === "tree-unreadable", show(h));
  const ch = X.cli(["--repo", head], ["f.txt"]);
  check("unreadable HEAD tree: CLI exits 2", ch.code === 2, `exit=${ch.code} ${ch.err}`);
  check("unreadable HEAD tree: CLI stderr names tree-unreadable", ch.err.includes("cannot resolve parents (tree-unreadable)"), ch.err);
};

module.exports = C;
