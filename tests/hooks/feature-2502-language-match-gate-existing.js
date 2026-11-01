"use strict";
// Tests: hooks/block-case-markers.js, hooks/pre-commit.d/checks/tests-frontmatter/language-match-gate.js, hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js
// Tags: TL2, hooks, pre-commit, edit-time, block-reason, test-language-match, scope:issue-specific, dup-group-keep:size-hard-limit, case-markers, unsupported, warn-context
// #2502 S4-4b rule b through both callers (edit-time hook and pre-commit gate), the hook's
// block-reason headings, and the S3-5 reader-less WARN (bodies in the sibling folder).
// Split from feature-2502-language-match-gate.js for run time; fixtures in its sibling folder.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2502-lmg-ex-"));
const NEUTRAL = path.join(ROOT, "cwd");
const DECOY = path.join(ROOT, "decoy");
fs.mkdirSync(NEUTRAL);
fs.mkdirSync(DECOY);
process.env.AGENTS_MAIN_ROOT = DECOY;
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const { MB, ME, bashBody, git, writeRel, make } = require("./feature-2502-language-match-gate/common");
const { BODY } = require("./feature-2502-language-match-gate/self-impl-helpers");
const { mkRepo, runHook, runPrecommitCaseMarkers, row } = make({ ROOT, NEUTRAL, gitInit });

// #2502 S4-4b rule b: an existing marker-less file is judged for case addition unless its working
// copy's Tests: header lists exactly one path. The added lines are plain echo, never a self-implemented harness.
caseBegin("existing-file-one-path-case-added-approves", "hooks/pre-commit.d/checks/tests-frontmatter/language-match-gate.js");
test("an existing one-path bash test gaining a code line passes both callers", () => {
  row({ rel: "tests/bin/old.sh", head: BODY.shClean, work: BODY.shClean + "echo extra\n", code: null });
});
caseEnd();

caseBegin("existing-file-two-paths-case-added-blocks", "hooks/pre-commit.d/checks/tests-frontmatter/language-match-gate.js");
test("an existing two-path bash test without markers gaining a code line is blocked by both callers", () => {
  const work = BODY.shTwoPathsNoMarkers + "echo extra\n";
  row({ rel: "tests/bin/old.sh", head: BODY.shTwoPathsNoMarkers, work, code: "CASE_ADDED_WITHOUT_MARKERS" });
});
caseEnd();

caseBegin("existing-file-two-paths-value-rewrite-approves", "hooks/pre-commit.d/checks/tests-frontmatter/language-match-gate.js");
test("an existing two-path bash test without markers whose line is rewritten passes both callers", () => {
  const work = BODY.shTwoPathsNoMarkers.replace("echo no markers", "echo changed");
  assert.notStrictEqual(work, BODY.shTwoPathsNoMarkers);
  row({ rel: "tests/bin/old.sh", head: BODY.shTwoPathsNoMarkers, work, code: null });
});
caseEnd();

// Block-reason headings (security review LOW): bodies in feature-2502-language-match-gate/.
const headings = require("./feature-2502-language-match-gate/reason-headings");
const H = { mkRepo, bashBody, runHook, MB, ME };

caseBegin("language-match-only-reason-heading", "hooks/block-case-markers.js");
headings.languageMatchOnlyHeading(H);
caseEnd();

caseBegin("both-gates-reason-headings", "hooks/block-case-markers.js");
headings.bothHeadings(H);
caseEnd();

caseBegin("case-marker-only-reason-unchanged", "hooks/block-case-markers.js");
headings.caseMarkerOnlyUnchanged(H);
caseEnd();

// S3-5 reader-less WARN at edit time and commit time: bodies in feature-2502-language-match-gate/.
const readerless = require("./feature-2502-language-match-gate/readerless-warn");
const RL = { mkRepo, runHook, runPrecommitCaseMarkers, git, writeRel };

caseBegin("readerless-new-file-edit-time-warn", "hooks/block-case-markers.js");
readerless.editTimeWarn(RL);
caseEnd();

caseBegin("readerless-new-file-commit-time-warn", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
readerless.commitTimeWarn(RL);
caseEnd();

caseBegin("readerless-negatives-edit-time-no-warn", "hooks/block-case-markers.js");
readerless.editTimeNegatives(RL);
caseEnd();

caseBegin("readerless-negatives-commit-time-no-warn", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
readerless.commitTimeNegatives(RL);
caseEnd();

// #2865 G1: placedTargets keeps a file some parent already has; newTargets (the case-marker gate's scope) drops it.
caseBegin("g1-placed-targets-vs-new-targets", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("G1 (#2865): placedTargets includes a file present in a parent, newTargets excludes it and keeps the new file", async () => {
  const CHECKOUT = require("./feature-2502-language-match-gate/common").CHECKOUT;
  const pcd = path.join(CHECKOUT, "hooks", "pre-commit.d");
  const gateMod = require(path.join(pcd, "checks", "tests-frontmatter", "case-markers-gate.js"));
  assert.strictEqual(typeof gateMod.placedTargets, "function", "case-markers-gate exports placedTargets");
  assert.strictEqual(typeof gateMod.newTargets, "function", "case-markers-gate still exports newTargets");
  assert.strictEqual(typeof gateMod.gate, "function", "case-markers-gate still exports gate");
  const old = "tests/bin/old.js";
  const fresh = "tests/bin/fresh.js";
  const repo = mkRepo({ [old]: BODY.jsTwoPathsNoMarkers });
  writeRel(repo, old, BODY.jsTwoPathsNoMarkers + "// modified\n");
  writeRel(repo, fresh, BODY.jsTwoPathsNoMarkers);
  git(repo, "add", "--", old, fresh);
  const env = process.env;
  const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: CHECKOUT, repoTop: repo, env, isTTY: false });
  const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
  const files = await snapshot.files();
  const rels = (t) => t.map((x) => x.rel).sort();
  const placed = gateMod.placedTargets({ context, snapshot, files });
  assert.ok(Array.isArray(placed), "the registry is readable");
  assert.deepStrictEqual(rels(placed), [fresh, old].sort());
  assert.strictEqual(placed.asked, true);
  for (const t of placed) assert.ok(t.entry && t.entry.id === "js", `${t.rel} carries the js entry`);
  const added = gateMod.newTargets({ context, snapshot, files });
  assert.deepStrictEqual(rels(added), [fresh]);
  assert.strictEqual(added.asked, true);
  assert.strictEqual(added[0].entry.id, "js");
  // the case-marker gate's output is unchanged: the new file is judged, the existing one is not
  const g = gateMod.gate({ context, snapshot, files });
  const text = g.messages.map((m) => String(m.text)).join("\n");
  assert.strictEqual(g.block, true, text);
  assert.ok(text.includes(fresh) && !text.includes(old), text);
});
caseEnd();

caseBegin("g1-placed-targets-excludes-deletion", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("G1 (#2865): a staged deletion (git rm) of a HEAD plain script is not in placedTargets", async () => {
  const CHECKOUT = require("./feature-2502-language-match-gate/common").CHECKOUT;
  const pcd = path.join(CHECKOUT, "hooks", "pre-commit.d");
  const gateMod = require(path.join(pcd, "checks", "tests-frontmatter", "case-markers-gate.js"));
  assert.strictEqual(typeof gateMod.placedTargets, "function", "case-markers-gate exports placedTargets");
  const gone = "tests/bin/gone.js";
  const kept = "tests/bin/kept.js";
  const repo = mkRepo({ [gone]: BODY.jsTwoPathsNoMarkers, [kept]: BODY.jsTwoPathsNoMarkers });
  writeRel(repo, kept, BODY.jsTwoPathsNoMarkers + "// modified\n");
  git(repo, "add", "--", kept);
  git(repo, "rm", "-q", "--", gone);
  const env = process.env;
  const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: CHECKOUT, repoTop: repo, env, isTTY: false });
  const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
  const files = await snapshot.files();
  const placed = gateMod.placedTargets({ context, snapshot, files });
  assert.ok(Array.isArray(placed), "the registry is readable");
  assert.deepStrictEqual(placed.map((x) => x.rel).sort(), [kept]);
});
caseEnd();

caseBegin("g1-placed-targets-excludes-non-placed", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("G1 (#2865): modified plain scripts in HEAD under tests/lib/ and a sibling module folder are not in placedTargets", async () => {
  const CHECKOUT = require("./feature-2502-language-match-gate/common").CHECKOUT;
  const pcd = path.join(CHECKOUT, "hooks", "pre-commit.d");
  const gateMod = require(path.join(pcd, "checks", "tests-frontmatter", "case-markers-gate.js"));
  assert.strictEqual(typeof gateMod.placedTargets, "function", "case-markers-gate exports placedTargets");
  const lib = "tests/lib/x.js";
  const helper = "tests/bin/sib/helper.js";
  const placedRel = "tests/bin/sib.js";
  const repo = mkRepo({ [lib]: BODY.jsTwoPathsNoMarkers, [helper]: BODY.jsTwoPathsNoMarkers, [placedRel]: BODY.jsTwoPathsNoMarkers });
  for (const rel of [lib, helper, placedRel]) writeRel(repo, rel, BODY.jsTwoPathsNoMarkers + "// modified\n");
  git(repo, "add", "--", lib, helper, placedRel);
  const env = process.env;
  const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: CHECKOUT, repoTop: repo, env, isTTY: false });
  const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
  const files = await snapshot.files();
  const placed = gateMod.placedTargets({ context, snapshot, files });
  assert.ok(Array.isArray(placed), "the registry is readable");
  assert.deepStrictEqual(placed.map((x) => x.rel).sort(), [placedRel]);
});
caseEnd();

caseBegin("g1-placed-targets-excludes-untouched-legacy", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("G1 (#2865): a placed plain script in HEAD that is not part of the change is not in placedTargets", async () => {
  const CHECKOUT = require("./feature-2502-language-match-gate/common").CHECKOUT;
  const pcd = path.join(CHECKOUT, "hooks", "pre-commit.d");
  const gateMod = require(path.join(pcd, "checks", "tests-frontmatter", "case-markers-gate.js"));
  assert.strictEqual(typeof gateMod.placedTargets, "function", "case-markers-gate exports placedTargets");
  const legacy = "tests/bin/legacy.js";
  const other = "tests/bin/other.js";
  const repo = mkRepo({ [legacy]: BODY.jsTwoPathsNoMarkers, [other]: BODY.jsTwoPathsNoMarkers });
  writeRel(repo, other, BODY.jsTwoPathsNoMarkers + "// modified\n");
  git(repo, "add", "--", other);
  const env = process.env;
  const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: CHECKOUT, repoTop: repo, env, isTTY: false });
  const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
  const files = await snapshot.files();
  const placed = gateMod.placedTargets({ context, snapshot, files });
  assert.ok(Array.isArray(placed), "the registry is readable");
  assert.deepStrictEqual(placed.map((x) => x.rel).sort(), [other]);
  assert.ok(!placed.some((x) => x.rel === legacy), "legacy.js is not named");
});
caseEnd();

caseBegin("g1-placed-targets-no-helper-library", "hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js");
test("G1 (#2865): a repo without the helper library has no placedTargets (the gate has nothing to judge)", async () => {
  const CHECKOUT = require("./feature-2502-language-match-gate/common").CHECKOUT;
  const pcd = path.join(CHECKOUT, "hooks", "pre-commit.d");
  const gateMod = require(path.join(pcd, "checks", "tests-frontmatter", "case-markers-gate.js"));
  assert.strictEqual(typeof gateMod.placedTargets, "function", "case-markers-gate exports placedTargets");
  const old = "tests/bin/old.js";
  const fresh = "tests/bin/fresh.js";
  const repo = mkRepo({ [old]: BODY.jsTwoPathsNoMarkers }, { noHelpers: true });
  writeRel(repo, old, BODY.jsTwoPathsNoMarkers + "// modified\n");
  writeRel(repo, fresh, BODY.jsTwoPathsNoMarkers);
  git(repo, "add", "--", old, fresh);
  const env = process.env;
  const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: CHECKOUT, repoTop: repo, env, isTTY: false });
  const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
  const files = await snapshot.files();
  const placed = gateMod.placedTargets({ context, snapshot, files });
  assert.deepStrictEqual([...placed], []);
});
caseEnd();
