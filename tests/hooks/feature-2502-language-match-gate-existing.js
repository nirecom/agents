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
