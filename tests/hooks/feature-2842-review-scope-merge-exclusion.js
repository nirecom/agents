"use strict";
// Tests: hooks/workflow-gate/review-tests-evidence.js
// Tags: TL2, review-tests, review-scope, merge-incoming, scope:issue-specific
// #2842 — the review scope drops merge-incoming paths (index blob and mode equal to MERGE_HEAD):
// main's tests and impl staged by `git merge --no-commit` are not this branch's work. Paths the
// branch changed, and conflict resolutions that differ from MERGE_HEAD, stay in scope. An
// undecidable merge state (octopus / non-OID MERGE_HEAD) excludes nothing (the old behaviour).
// TL3 gap (what this test does NOT catch):
// - a real /review-tests run during a merge picking up the narrowed scope (tests/bin/feature-2842-*)
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2842mx-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const ev = require(path.join(ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));

const git = (dir, ...a) => {
  const r = spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
  return r;
};
const gitOk = (dir, ...a) => {
  const r = git(dir, ...a);
  assert.strictEqual(r.status, 0, `git ${a.join(" ")}: ${r.stderr}`);
  return r.stdout;
};
const put = (d, rel, body) => {
  fs.mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
  fs.writeFileSync(path.join(d, rel), `${body}\n`);
};
let seq = 0;
function base() {
  const d = path.join(TMP, `repo-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  gitOk(d, "config", "user.email", "t@example.invalid");
  gitOk(d, "config", "user.name", "T");
  gitOk(d, "config", "core.autocrlf", "false");
  gitOk(d, "checkout", "-q", "-b", "mainline");
  put(d, "README.md", "seed");
  put(d, "hooks/shared.js", "shared v1");
  put(d, "hooks/both.js", "both v1");
  gitOk(d, "add", "-A");
  gitOk(d, "commit", "-qm", "base");
  return d;
}
// merging() -> a repo mid-merge of mainline into feature, plus the branch's own staged work:
// main brought tests/main-a.sh, tests/main-b.sh, hooks/shared.js (v2); both sides changed
// hooks/both.js, resolved to a third content; the branch stages tests/branch.sh and hooks/branch.js.
function merging() {
  const d = base();
  gitOk(d, "checkout", "-q", "-b", "feature");
  put(d, "hooks/both.js", "both feature");
  gitOk(d, "commit", "-qam", "feature");
  gitOk(d, "checkout", "-q", "mainline");
  put(d, "tests/main-a.sh", "echo main a");
  put(d, "tests/main-b.sh", "echo main b");
  put(d, "hooks/shared.js", "shared v2");
  put(d, "hooks/both.js", "both main");
  gitOk(d, "add", "-A");
  gitOk(d, "commit", "-qm", "main");
  gitOk(d, "checkout", "-q", "feature");
  git(d, "merge", "-q", "--no-commit", "--no-ff", "mainline");
  assert.ok(fs.existsSync(path.join(d, ".git", "MERGE_HEAD")), "fixture reached a merge in progress");
  put(d, "hooks/both.js", "both resolved");
  branchWork(d);
  gitOk(d, "add", "--", "hooks/both.js");
  return d;
}
function branchWork(d) {
  put(d, "tests/branch.sh", "echo branch");
  put(d, "hooks/branch.js", "branch impl");
  gitOk(d, "add", "--", "tests/branch.sh", "hooks/branch.js");
}
// twin() -> the same base with only the branch's own work staged and no merge.
function twin() {
  const d = base();
  gitOk(d, "checkout", "-q", "-b", "feature");
  put(d, "hooks/both.js", "both feature");
  gitOk(d, "commit", "-qam", "feature");
  put(d, "hooks/both.js", "both resolved");
  branchWork(d);
  gitOk(d, "add", "--", "hooks/both.js");
  return d;
}
const keys = (m) => Object.keys(m.files || {}).sort();
const stateOf = (r) => (typeof r.mergeState === "string" ? r.mergeState : r.mergeState && r.mergeState.state);
// excluded may be carried as a count or as the excluded paths; the count is what the plan pins.
const excludedCount = (r) => (typeof r.excluded === "number" ? r.excluded : Array.from(r.excluded || []).length);
const mergeHeadOf =(d) => fs.readFileSync(path.join(d, ".git", "MERGE_HEAD"), "utf8").trim();
const ALL = ["hooks/both.js", "hooks/branch.js", "hooks/shared.js", "tests/branch.sh", "tests/main-a.sh", "tests/main-b.sh"];
const OWN = ["hooks/both.js", "hooks/branch.js", "tests/branch.sh"];

caseBegin("merge-exclusion-manifest", "hooks/workflow-gate/review-tests-evidence.js");
test("M1: not merging -> the manifest is the plain staged set and mergeExcluded is 0", () => {
  const d = twin();
  const m = ev.computeReviewScopeManifest(d);
  assert.strictEqual(m.ok, true, m.error);
  assert.deepStrictEqual(keys(m), OWN);
  assert.strictEqual(m.mergeExcluded, 0, "mergeExcluded is reported (0) when not merging");
});
test("M2: merging -> main's tests and impl are excluded; branch-only and conflict-resolved paths stay", () => {
  const d = merging();
  const m = ev.computeReviewScopeManifest(d);
  assert.strictEqual(m.ok, true, m.error);
  assert.deepStrictEqual(keys(m), OWN, "merge-incoming tests/main-*.sh and hooks/shared.js are dropped");
  assert.strictEqual(m.mergeExcluded, 3, "three merge-incoming paths were excluded");
});
test("M3: the merged scope fingerprints identically to the branch's own scope without the merge", () => {
  const merged = ev.computeReviewScopeFingerprint(merging());
  const own = ev.computeReviewScopeFingerprint(twin());
  assert.strictEqual(merged.ok, true);
  assert.strictEqual(merged.fingerprint, own.fingerprint, "the merge does not move the fingerprint");
  assert.strictEqual(merged.testCount, 1, "testCount counts only tests/branch.sh");
});
test("M4: undecidable merge states (octopus MERGE_HEAD, non-OID MERGE_HEAD) exclude nothing", () => {
  for (const [label, body] of [["octopus", (h) => `${h}\n${h}\n`], ["non-oid", () => "not-an-oid\n"]]) {
    const d = merging();
    fs.writeFileSync(path.join(d, ".git", "MERGE_HEAD"), body(mergeHeadOf(d)));
    const m = ev.computeReviewScopeManifest(d);
    assert.strictEqual(m.ok, true, `${label}: ${m.error}`);
    assert.deepStrictEqual(keys(m), ALL, `${label}: every staged path stays`);
    assert.strictEqual(m.mergeExcluded, 0, `${label}: nothing excluded`);
  }
});
caseEnd();

caseBegin("merge-exclusion-drop-helper", "hooks/workflow-gate/review-tests-evidence.js");
test("M5: dropMergeIncomingPaths returns {paths, mergeState, excluded} for each state", () => {
  assert.strictEqual(typeof ev.dropMergeIncomingPaths, "function", "dropMergeIncomingPaths is exported");
  const d = merging();
  const r = ev.dropMergeIncomingPaths(d, ALL.slice());
  assert.deepStrictEqual(Array.from(r.paths).sort(), OWN);
  assert.strictEqual(excludedCount(r), 3, "three merge-incoming paths are reported as excluded");
  assert.strictEqual(stateOf(r), "merging");
  const plain = ev.dropMergeIncomingPaths(twin(), OWN.slice());
  assert.deepStrictEqual(Array.from(plain.paths).sort(), OWN);
  assert.strictEqual(excludedCount(plain), 0);
  assert.strictEqual(stateOf(plain), "not-merging");
  fs.writeFileSync(path.join(d, ".git", "MERGE_HEAD"), "not-an-oid\n");
  const und = ev.dropMergeIncomingPaths(d, ALL.slice());
  assert.deepStrictEqual(Array.from(und.paths).sort(), ALL, "undecidable passes the input through");
  assert.strictEqual(stateOf(und), "undecidable");
});
caseEnd();
