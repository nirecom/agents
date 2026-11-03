#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests.js
// Tags: TL2, hooks, run-tests, run-parts, dispatch-outcome, scope:issue-specific
// #2688 T7: partial reruns merge into one run_tests verdict. The selection comes from the
// run's own evidence (payload test_args, or the run-all arguments on stdout); anything it
// cannot prove is "unknown" and recorded alone. Parts live in feature-2688-run-parts/.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2688-run-parts");
// input_version resolves its merge base against the protected branches; pin them.
process.env.DEFAULT_BRANCHES = "main,master";
const merge = require("./feature-2688-run-parts/merge");
const unknown = require("./feature-2688-run-parts/unknown");
const version = require("./feature-2688-run-parts/version");

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

caseBegin("partial-rerun-merges-over-the-full-run", "hooks/workflow-run-tests/run-parts.js");
test("partial-rerun-merges-over-the-full-run", () => noNewFailures(fails, merge.mergesWorkerSelections));
caseEnd();

caseBegin("full-run-rebuilds-run-parts", "hooks/workflow-run-tests/run-parts.js");
test("full-run-rebuilds-run-parts", () => noNewFailures(fails, merge.fullRunRebuilds));
caseEnd();

caseBegin("hit-cleared-only-when-its-id-reruns-clean", "hooks/workflow-run-tests/run-parts.js");
test("hit-cleared-only-when-its-id-reruns-clean", () => noNewFailures(fails, merge.hitClearedOnlyWhenRerunClean));
caseEnd();

caseBegin("unrunnable-never-merges-away", "hooks/workflow-run-tests/run-parts.js");
test("unrunnable-never-merges-away", () => noNewFailures(fails, merge.unrunnableNeverMergesAway));
caseEnd();

caseBegin("count-mismatch-selection-is-unknown", "hooks/workflow-run-tests/run-parts.js");
test("count-mismatch-selection-is-unknown", () => noNewFailures(fails, unknown.countMismatchIsUnknown));
caseEnd();

caseBegin("flag-or-directory-selection-is-unknown", "hooks/workflow-run-tests/run-parts.js");
test("flag-or-directory-selection-is-unknown", () => noNewFailures(fails, unknown.flagOrDirectoryArgumentIsUnknown));
caseEnd();

caseBegin("failing-outside-selection-is-unknown", "hooks/workflow-run-tests/run-parts.js");
test("failing-outside-selection-is-unknown", () => noNewFailures(fails, unknown.failingOutsideSelectionIsUnknown));
caseEnd();

caseBegin("stdout-route-path-without-result-line-is-unknown", "hooks/workflow-run-tests.js");
test("stdout-route-path-without-result-line-is-unknown", () => noNewFailures(fails, unknown.stdoutPathWithoutLineIsUnknown));
caseEnd();

caseBegin("input-version-mismatch-drops-the-older-part", "hooks/workflow-run-tests/run-parts.js");
test("input-version-mismatch-drops-the-older-part", () => noNewFailures(fails, version.versionMismatchDropsTheOlderPart));
caseEnd();

caseBegin("null-input-version-merges-nothing", "hooks/workflow-run-tests/run-parts.js");
test("null-input-version-merges-nothing", () => noNewFailures(fails, version.nullVersionMergesNothing));
caseEnd();
