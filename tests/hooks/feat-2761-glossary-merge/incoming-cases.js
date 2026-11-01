"use strict";
// Private cases of tests/hooks/feat-2761-glossary-merge-scope.js, A group: detectMergeIncoming(repoDir,
// stagedPaths) on real fixture repos — every state and every reachable undecidable reason, the subset
// rule, index versus worktree, linked worktrees, the Git Bash drive form, and a branch named MERGE_HEAD.
// Requires the caller's isolate() pins first. The `exception` reason has no outside trigger and is not driven.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { caseBegin, caseEnd } = require("../../lib/harness");
const { noNewFailures } = require("../../lib/case-verdict");
const F = require("../../lib/glossary-check-fixture");
const M = require("./fixture");

const MODULE = "hooks/lib/merge-incoming.js";
const WORD = F.VARIANT;
let loaded;
// The module, or null (one FAIL per case) while it does not exist yet.
function modOrNull(label) {
  if (loaded === undefined) {
    try {
      loaded = require(path.join(F.ROOT, MODULE));
    } catch (e) {
      loaded = { loadError: e.code || e.message };
    }
  }
  if (loaded.loadError) {
    F.check(`${label}: ${MODULE} loads`, false, loaded.loadError);
    return null;
  }
  return loaded;
}

function detect(label, repoDir, stagedPaths) {
  const m = modOrNull(label);
  if (!m) return null;
  try {
    return m.detectMergeIncoming(repoDir, stagedPaths);
  } catch (e) {
    F.check(`${label}: detectMergeIncoming does not throw`, false, (e && e.stack) || e);
    return null;
  }
}

const show = (r) => JSON.stringify(r, (k, v) => (v instanceof Set ? [...v].sort() : v));
const sameSet = (set, list) => set instanceof Set && set.size === list.length && list.every((p) => set.has(p));
const guarded = (name, fn) => M.guarded(F.check, name, fn);
// One node:test case: it fails when any F.check inside it (or an exception, via guarded) adds a failure.
const caseTest = (name, fn) => test(name, () => noNewFailures(F.failureCount, () => guarded(name, fn)));

function expectState(label, r, state, reason) {
  const ok = !!r && r.state === state && (reason === undefined || r.reason === reason);
  return F.check(`${label}: ${state}${reason ? ` / ${reason}` : ""}`, ok, show(r));
}

const INCOMING = ["docs/main-only.md", "docs/old.md", "src/main-only.js", "tests/main-only.sh"];

function run() {
caseBegin("exports the three frozen states", "hooks/lib/merge-incoming.js");
caseTest("A0", () => {
  const m = modOrNull("A0 exports");
  const s = m && m.MERGE_INCOMING_STATE;
  F.check("A0 MERGE_INCOMING_STATE holds the three states, frozen",
    !!s && s.NOT_MERGING === "not-merging" && s.MERGING === "merging" && s.UNDECIDABLE === "undecidable" && Object.isFrozen(s), show(s));
});
caseEnd();

caseBegin("not merging with staged changes", "hooks/lib/merge-incoming.js");
caseTest("A1", () => {
  const repo = F.mkRepo("a1");
  F.stageFile(repo, "docs/guide.md", "# Guide\n\nText.\n");
  F.check("A1 precondition: no MERGE_HEAD file", !fs.existsSync(M.mergeHeadPathOf(repo)), M.mergeHeadPathOf(repo));
  expectState("A1 staged change outside a merge", detect("A1", repo, M.stagedNames(repo)), "not-merging");
});
caseEnd();

caseBegin("standard merge lists exactly the merge-incoming files", "hooks/lib/merge-incoming.js");
caseTest("A2", () => {
  const repo = F.mkRepo("a2");
  const fx = M.standardMerge(repo, WORD);
  const staged = M.stagedNames(repo);
  F.check("A2 precondition: staged set is the incoming files plus docs/shared.md",
    sameSet(new Set(staged), INCOMING.concat(["docs/shared.md"])), staged.join(","));
  const r = detect("A2", repo, staged);
  if (expectState("A2 standard merge", r, "merging")) {
    F.check("A2 paths are exactly the four incoming paths (docs/shared.md left in scope)", sameSet(r.paths, INCOMING), show(r));
    F.check("A2 mergeHead is the MERGE_HEAD oid", r.mergeHead === fx.mergeHead, `${r.mergeHead} vs ${fx.mergeHead}`);
  }
  const before = fs.readFileSync(fx.mergeHeadPath, "utf8");
  const again = detect("A2 again", repo, staged);
  F.check("A2 a second call gives the same result", !!r && show(again) === show(r), show(again));
  F.check("A2 the calls leave MERGE_HEAD and the staged set untouched",
    fs.readFileSync(fx.mergeHeadPath, "utf8") === before && M.stagedNames(repo).join(",") === staged.join(","), "changed");
});
caseEnd();

caseBegin("incoming file edited again during the merge leaves the set", "hooks/lib/merge-incoming.js");
caseTest("A3", () => {
  const repo = F.mkRepo("a3");
  M.standardMerge(repo, WORD);
  M.apply(repo, { "docs/main-only.md": "# Main only\n\nEdited during the merge.\n" });
  const r = detect("A3", repo, M.stagedNames(repo));
  if (expectState("A3 edited incoming file", r, "merging")) {
    F.check("A3 docs/main-only.md is no longer merge-incoming", !r.paths.has("docs/main-only.md") && r.paths.has("src/main-only.js"), show(r));
  }
});
caseEnd();

caseBegin("index-only path and resolution deletion stay in scope", "hooks/lib/merge-incoming.js");
caseTest("A4", () => {
  const repo = F.mkRepo("a4");
  M.standardMerge(repo, WORD, { resolve: { "docs/shared.md": null, "docs/new-in-merge.md": "# New\n\nText.\n" } });
  const staged = M.stagedNames(repo);
  F.check("A4 precondition: both paths are staged", staged.includes("docs/shared.md") && staged.includes("docs/new-in-merge.md"), staged.join(","));
  const r = detect("A4", repo, staged);
  if (expectState("A4 index-only and resolved-deleted paths", r, "merging")) {
    F.check("A4 the index-only path is not merge-incoming", !r.paths.has("docs/new-in-merge.md"), show(r));
    F.check("A4 the path deleted by the resolution (present in MERGE_HEAD) is not merge-incoming", !r.paths.has("docs/shared.md"), show(r));
    F.check("A4 the incoming deletion docs/old.md is merge-incoming", r.paths.has("docs/old.md"), show(r));
  }
});
caseEnd();

caseBegin("paths is always a subset of stagedPaths", "hooks/lib/merge-incoming.js");
caseTest("A5", () => {
  const repo = F.mkRepo("a5");
  M.standardMerge(repo, WORD);
  const part = detect("A5 part", repo, ["docs/main-only.md", "docs/shared.md"]);
  if (expectState("A5 two of the staged paths", part, "merging")) {
    F.check("A5 only the passed incoming path comes back", sameSet(part.paths, ["docs/main-only.md"]), show(part));
  }
  const none = detect("A5 empty", repo, []);
  if (expectState("A5 empty stagedPaths", none, "merging")) F.check("A5 empty stagedPaths gives an empty Set", sameSet(none.paths, []), show(none));
  const all = detect("A5 all", repo, M.stagedNames(repo));
  const staged = new Set(M.stagedNames(repo));
  F.check("A5 every returned path is one of stagedPaths", !!all && all.paths instanceof Set && [...all.paths].every((p) => staged.has(p)), show(all));
});
caseEnd();

caseBegin("octopus merge is undecidable", "hooks/lib/merge-incoming.js");
caseTest("A6", () => {
  const repo = F.mkRepo("a6");
  const fx = M.octopusMerge(repo, WORD);
  F.check("A6 precondition: git wrote two MERGE_HEAD lines", fx.lines.length === 2, fx.lines.join("|"));
  expectState("A6 octopus", detect("A6", repo, M.stagedNames(repo)), "undecidable", "octopus");
});
caseEnd();

caseBegin("malformed or dangling MERGE_HEAD is undecidable", "hooks/lib/merge-incoming.js");
caseTest("A7", () => {
  for (const [label, body] of [["not-an-oid", "not-an-oid\n"], ["empty file", ""], ["short hex", "abc123\n"]]) {
    const repo = F.mkRepo(`a7-${label.replace(/\W+/g, "")}`);
    fs.writeFileSync(M.mergeHeadPathOf(repo), body);
    expectState(`A7 MERGE_HEAD ${label}`, detect(`A7 ${label}`, repo, ["README.md"]), "undecidable", "merge-head-malformed");
  }
  const repo = F.mkRepo("a7-missing");
  M.standardMerge(repo, WORD);
  M.corruptMergeHead(repo);
  expectState("A7 MERGE_HEAD names a missing object", detect("A7 missing object", repo, M.stagedNames(repo)), "undecidable", "diff-failed");
});
caseEnd();

caseBegin("failures come back as undecidable without throwing", "hooks/lib/merge-incoming.js");
caseTest("A8", () => {
  const plain = fs.mkdtempSync(path.join(os.tmpdir(), "g2761-nogit-"));
  expectState("A8 not a git repository", detect("A8 no repo", plain, ["a.md"]), "undecidable", "git-path-failed");
  expectState("A8 repoDir null", detect("A8 null", null, []), "undecidable", "invalid-argument");
  expectState("A8 stagedPaths not an array", detect("A8 non-array", F.mkRepo("a8-arg"), "docs/a.md"), "undecidable", "invalid-argument");
  const repo = F.mkRepo("a8-dir");
  fs.mkdirSync(M.mergeHeadPathOf(repo));
  expectState("A8 MERGE_HEAD is a directory", detect("A8 unreadable", repo, ["README.md"]), "undecidable", "merge-head-unreadable");
});
caseEnd();

caseBegin("linked worktree has its own MERGE_HEAD", "hooks/lib/merge-incoming.js");
caseTest("A9", () => {
  const repo = F.mkRepo("a9");
  const wt = F.addWorktree(repo, `a9-${process.pid}`);
  M.standardMerge(wt, WORD);
  const r = detect("A9 worktree", wt, M.stagedNames(wt));
  if (expectState("A9 inside the merging worktree", r, "merging")) F.check("A9 worktree paths are the incoming files", sameSet(r.paths, INCOMING), show(r));
  expectState("A9 main worktree at the same time", detect("A9 main", repo, ["README.md"]), "not-merging");
});
caseEnd();

caseBegin("Git Bash drive form of repoDir gives the same result", "hooks/lib/merge-incoming.js");
test("A10", (t) => {
  if (process.platform !== "win32") {
    t.skip("A10 drive-letter form is Windows-only");
    return undefined;
  }
  return noNewFailures(F.failureCount, () => guarded("A10", () => {
  const repo = F.mkRepo("a10");
  M.standardMerge(repo, WORD);
  const posix = M.toPosixDrive(repo);
  F.check("A10 precondition: the repoDir is in /c/... form", /^\/[a-z]\//.test(posix), posix);
  const r = detect("A10", posix, M.stagedNames(repo));
  if (expectState("A10 /c/... repoDir", r, "merging")) F.check("A10 paths match A2", sameSet(r.paths, INCOMING), show(r));
}));
});
caseEnd();

caseBegin("branch named MERGE_HEAD is not a merge", "hooks/lib/merge-incoming.js");
caseTest("A11", () => {
  const repo = F.mkRepo("a11");
  F.stageFile(repo, "docs/guide.md", "# Guide\n\nText.\n");
  F.check("A11 precondition: git rev-parse -q --verify MERGE_HEAD succeeds through the branch", M.makeMergeHeadBranch(repo), "rev-parse failed");
  F.check("A11 precondition: still no MERGE_HEAD file", !fs.existsSync(M.mergeHeadPathOf(repo)), M.mergeHeadPathOf(repo));
  expectState("A11 same-name branch", detect("A11", repo, M.stagedNames(repo)), "not-merging");
});
caseEnd();

caseBegin("the index, not the worktree, is compared with MERGE_HEAD", "hooks/lib/merge-incoming.js");
caseTest("A12", () => {
  const rel = "docs/main-only.md";
  const a = F.mkRepo("a12-staged");
  M.standardMerge(a, WORD);
  const sa = M.stagedEditWorktreeAtMergeHead(a, rel, WORD);
  F.check("A12a precondition: index differs from MERGE_HEAD, worktree equals it", !sa.indexIsMergeHead && sa.worktreeIsMergeHead, JSON.stringify(sa));
  const ra = detect("A12a", a, M.stagedNames(a));
  if (expectState("A12a staged edit, worktree back at MERGE_HEAD", ra, "merging")) {
    F.check(`A12a ${rel} is not merge-incoming (the staged blob differs)`, !ra.paths.has(rel) && ra.paths.has("src/main-only.js"), show(ra));
  }
  const b = F.mkRepo("a12-worktree");
  M.standardMerge(b, WORD);
  const sb = M.worktreeOnlyEdit(b, rel);
  F.check("A12b precondition: index equals MERGE_HEAD, worktree differs", sb.indexIsMergeHead && !sb.worktreeIsMergeHead, JSON.stringify(sb));
  const rb = detect("A12b", b, M.stagedNames(b));
  if (expectState("A12b unstaged worktree edit", rb, "merging")) {
    F.check(`A12b ${rel} stays merge-incoming (the staged blob equals MERGE_HEAD)`, rb.paths.has(rel), show(rb));
  }
});
caseEnd();

// #2631 stage 9: MERGE_HEAD must name a commit (`<oid>^{commit}`). A tree oid is a valid tree-ish
// for `git diff --cached`, so without the peel it would pass as a merge and exclude files.
caseBegin("MERGE_HEAD naming a tree or a blob is undecidable", "hooks/lib/merge-incoming.js");
caseTest("A13", () => {
  for (const kind of ["tree", "blob"]) {
    const repo = F.mkRepo(`a13-${kind}`);
    const fx = M.standardMerge(repo, WORD);
    const oid = M.git(repo, ["rev-parse", kind === "tree" ? `${fx.mergeHead}^{tree}` : `${fx.mergeHead}:docs/main-only.md`]).stdout.trim();
    F.check(`A13 ${kind}: premise: the oid names a ${kind}`, M.git(repo, ["cat-file", "-t", oid]).stdout.trim() === kind, oid);
    fs.writeFileSync(fx.mergeHeadPath, `${oid}\n`);
    expectState(`A13 MERGE_HEAD is a ${kind} oid`, detect(`A13 ${kind}`, repo, M.stagedNames(repo)), "undecidable", "diff-failed");
  }
});
caseEnd();
}

module.exports = { run };
