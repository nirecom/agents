#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-state/dispatch-settlement.js, hooks/workflow-run-tests/run-parts.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests.js, skills/run-tests/scripts/show-dispatch-outcome.js, bin/workflow/lib/run-tests-baseline-evidence/preconditions.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, run-parts, fail-closed, scope:issue-specific
// #3063: a split /run-tests dispatch must never go green on the latest outcome alone. Every
// unconsumed dispatch is ingested in order; an unusable one, an unknown selection, a throwing
// merge or an unreadable control dir keeps run_tests pending. Parts: fix-3063-split-dispatch/.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f3063-split-dispatch");
// input_version resolves its merge base against the protected branches; pin them.
process.env.DEFAULT_BRANCHES = "main,master";
const concurrent = require("./fix-3063-split-dispatch/concurrent");
const selection = require("./fix-3063-split-dispatch/selection");
const drift = require("./fix-3063-split-dispatch/drift");
const display = require("./fix-3063-split-dispatch/display");
const overflow = require("./fix-3063-split-dispatch/overflow");

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

caseBegin("two-trusted-dispatches-both-ingested", "hooks/workflow-run-tests/dispatch-outcome.js");
test("two-trusted-dispatches-both-ingested", () => noNewFailures(fails, concurrent.bothTrustedDispatchesIngested));
caseEnd();

caseBegin("baseline-precondition-lists-every-unsettled-stem", "bin/workflow/lib/run-tests-baseline-evidence/preconditions.js");
test("baseline-precondition-lists-every-unsettled-stem", () => noNewFailures(fails, concurrent.preconditionListsEveryUnsettledStem));
caseEnd();

caseBegin("older-absent-stem-blocks-completion", "hooks/workflow-run-tests/dispatch-outcome.js");
test("older-absent-stem-blocks-completion", () => noNewFailures(fails, concurrent.absentOlderStemBlocksCompletion));
caseEnd();

caseBegin("older-untrusted-stem-blocks-completion", "hooks/workflow-run-tests/dispatch-outcome.js");
test("older-untrusted-stem-blocks-completion", () => noNewFailures(fails, concurrent.untrustedOlderStemBlocksCompletion));
caseEnd();

caseBegin("late-outcome-adds-its-failure", "hooks/workflow-run-tests/dispatch-outcome.js");
test("late-outcome-adds-its-failure", () => noNewFailures(fails, concurrent.lateOutcomeAddsItsFailure));
caseEnd();

caseBegin("full-run-supersedes-absent-stem", "hooks/workflow-run-tests/dispatch-outcome.js");
test("full-run-supersedes-absent-stem", () => noNewFailures(fails, concurrent.fullRunSupersedesAbsentStem));
caseEnd();

caseBegin("full-red-run-supersedes-absent-stem", "hooks/workflow-run-tests/dispatch-outcome.js");
test("full-red-run-supersedes-absent-stem", () => noNewFailures(fails, concurrent.fullRedRunSupersedesAbsentStem));
caseEnd();

caseBegin("late-full-green-does-not-rebuild-run-parts", "hooks/workflow-run-tests/run-parts.js");
test("late-full-green-does-not-rebuild-run-parts", () => noNewFailures(fails, concurrent.lateFullGreenDoesNotRebuild));
caseEnd();

caseBegin("late-green-path-keeps-newer-failure", "hooks/workflow-run-tests/run-parts.js");
test("late-green-path-keeps-newer-failure", () => noNewFailures(fails, concurrent.lateGreenPathKeepsNewerFailure));
caseEnd();

caseBegin("list-unconsumed-marks-late-stems", "hooks/workflow-state/dispatch-settlement.js");
test("list-unconsumed-marks-late-stems", () => noNewFailures(fails, concurrent.listUnconsumedMarksLateStems));
caseEnd();

caseBegin("unknown-failure-survives-proven-rerun", "hooks/workflow-run-tests/run-parts.js");
test("unknown-failure-survives-proven-rerun", () => noNewFailures(fails, selection.unknownFailureSurvivesProvenRerun));
caseEnd();

caseBegin("unknown-pass-keeps-full-run-failure", "hooks/workflow-run-tests/run-parts.js");
test("unknown-pass-keeps-full-run-failure", () => noNewFailures(fails, selection.unknownPassKeepsFullFailure));
caseEnd();

caseBegin("full-run-after-unknown-completes", "hooks/workflow-run-tests/run-parts.js");
test("full-run-after-unknown-completes", () => noNewFailures(fails, selection.fullRunAfterUnknownCompletes));
caseEnd();

caseBegin("lone-unknown-pass-stays-open", "hooks/workflow-run-tests/run-parts.js");
test("lone-unknown-pass-stays-open", () => noNewFailures(fails, selection.loneUnknownPassStaysOpen));
caseEnd();

caseBegin("jobs-only-run-is-full", "hooks/workflow-run-tests/run-parts.js");
test("jobs-only-run-is-full", () => noNewFailures(fails, selection.jobsOnlyRunIsFull));
caseEnd();

caseBegin("jobs-with-path-is-proven", "hooks/workflow-run-tests/run-parts.js");
test("jobs-with-path-is-proven", () => noNewFailures(fails, selection.jobsWithPathIsProven));
caseEnd();

caseBegin("unprovable-run-all-options-are-unknown", "hooks/workflow-run-tests/run-parts.js");
test("unprovable-run-all-options-are-unknown", () => noNewFailures(fails, selection.unprovableOptionsAreUnknown));
caseEnd();

caseBegin("selection-from-args-option-table", "hooks/workflow-run-tests/run-parts.js");
test("selection-from-args-option-table", () => noNewFailures(fails, selection.optionTableRows));
caseEnd();

caseBegin("merge-exception-fails-closed", "hooks/workflow-run-tests/record-run.js");
test("merge-exception-fails-closed", () => noNewFailures(fails, selection.mergeExceptionFailsClosed));
caseEnd();

caseBegin("window-overflow-via-hook-holds-open", "hooks/workflow-run-tests/run-parts.js");
test("window-overflow-via-hook-holds-open", () => noNewFailures(fails, overflow.overflowHoldsOpen));
caseEnd();

caseBegin("full-run-after-window-overflow-completes", "hooks/workflow-run-tests/record-run.js");
test("full-run-after-window-overflow-completes", () => noNewFailures(fails, overflow.fullRunAfterOverflowCompletes));
caseEnd();

caseBegin("option-table-covers-run-all-parser", "hooks/workflow-run-tests/run-parts.js");
test("option-table-covers-run-all-parser", () => noNewFailures(fails, drift.optionTableCoversRunAllParser));
caseEnd();

caseBegin("single-dispatch-display-unchanged", "skills/run-tests/scripts/show-dispatch-outcome.js");
test("single-dispatch-display-unchanged", () => noNewFailures(fails, display.singleDispatchDisplayUnchanged));
caseEnd();

caseBegin("unconsumed-stems-shown-in-dispatch-order", "skills/run-tests/scripts/show-dispatch-outcome.js");
test("unconsumed-stems-shown-in-dispatch-order", () => noNewFailures(fails, display.unconsumedStemsShownInOrder));
caseEnd();

caseBegin("untrusted-stem-shown-as-block", "skills/run-tests/scripts/show-dispatch-outcome.js");
test("untrusted-stem-shown-as-block", () => noNewFailures(fails, display.untrustedStemShownAsBlock));
caseEnd();

caseBegin("scan-failure-demotes-non-test-call", "hooks/workflow-run-tests/dispatch-outcome.js");
test("scan-failure-demotes-non-test-call", () => noNewFailures(fails, display.scanFailureDemotesNonTestCall));
caseEnd();

caseBegin("scan-failure-blocks-green-stdout-run", "hooks/workflow-run-tests.js");
test("scan-failure-blocks-green-stdout-run", () => noNewFailures(fails, display.scanFailureBlocksGreenStdoutRun));
caseEnd();

caseBegin("scan-failure-stops-baseline-precondition", "bin/workflow/lib/run-tests-baseline-evidence/preconditions.js");
test("scan-failure-stops-baseline-precondition", () => noNewFailures(fails, display.scanFailureStopsBaselinePrecondition));
caseEnd();

caseBegin("scan-failure-shown-as-block", "skills/run-tests/scripts/show-dispatch-outcome.js");
test("scan-failure-shown-as-block", () => noNewFailures(fails, display.scanFailureShownAsBlock));
caseEnd();

caseBegin("missing-control-dir-is-no-dispatch", "hooks/workflow-state/dispatch-settlement.js");
test("missing-control-dir-is-no-dispatch", () => noNewFailures(fails, display.missingControlDirIsNoDispatch));
caseEnd();
