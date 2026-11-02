#!/usr/bin/env node
"use strict";
// Tests: bin/worker-dispatch/workers/test-runner.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/dispatch-outcome.js, bin/run-tests-baseline, bin/lib/run-all-hits.sh, bin/lib/run-all-worktree-change-detect.sh
// Tags: TL2, bin, hooks, worker-dispatch, run-tests, baseline, hit-attribution, root-decoy, worktree-change-detection, integration, missing-test-file, scope:issue-specific
// #2669 end to end: the real dispatcher runs the real tests/run-all.sh over fixture tests that
// reach the command guard; the real run_tests hook reads what it left (file and stdout routes),
// and the real baseline CLI stops at the hit that run recorded. T10: the hook records the same
// hits from every route. T8: the worker module's log tail and hits list. Parts live in
// feature-2669-runner-hook-wiring/.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call here; the test wraps the
// dispatcher's real stdout in the hook's input JSON. One run per verdict, plus one hit-then-clean session.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { totals } = require("./feature-2669-runner-hook-wiring/common");
const realRun = require("./feature-2669-runner-hook-wiring/real-run");
const hitKinds = require("./feature-2669-runner-hook-wiring/hit-kinds");
const hookRoutes = require("./feature-2669-runner-hook-wiring/hook-routes");
const workerTail = require("./feature-2669-runner-hook-wiring/worker-tail");

const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

// Each group's prepare / init runs inside the group's first case, so it keeps its place between
// the groups (worker-tail's init stubs a module the earlier groups load for real).
caseBegin("real-run-with-hits-reaches-the-hook", "hooks/workflow-run-tests.js");
test("real-run-with-hits-reaches-the-hook", () => noNewFailures(fails, () => {
  realRun.prepare();
  realRun.withHits();
}));
caseEnd();

caseBegin("real-run-without-hits-stays-green", "hooks/workflow-run-tests.js");
test("real-run-without-hits-stays-green", () => noNewFailures(fails, realRun.withoutHits));
caseEnd();

caseBegin("a-clean-run-after-a-hit-run-clears-the-hits", "hooks/workflow-run-tests/dispatch-outcome.js");
test("a-clean-run-after-a-hit-run-clears-the-hits", () => noNewFailures(fails, realRun.hitThenCleanInOneSession));
caseEnd();

caseBegin("baseline-cli-stops-at-the-real-runs-hit", "bin/run-tests-baseline");
test("baseline-cli-stops-at-the-real-runs-hit", () => noNewFailures(fails, realRun.baselineOnRealRun));
caseEnd();

caseBegin("worktree-change-hit-reaches-the-hook-and-baseline-cli", "bin/lib/run-all-worktree-change-detect.sh");
test("worktree-change-hit-reaches-the-hook-and-baseline-cli", () => noNewFailures(fails, () => {
  hitKinds.prepare();
  hitKinds.worktreeChangeHit();
}));
caseEnd();

caseBegin("root-decoy-hit-reaches-the-hook-and-baseline-cli", "bin/lib/run-all-hits.sh");
test("root-decoy-hit-reaches-the-hook-and-baseline-cli", () => noNewFailures(fails, hitKinds.rootDecoyHit));
caseEnd();

caseBegin("every-route-records-the-same-hits", "hooks/workflow-run-tests.js");
test("every-route-records-the-same-hits", () => noNewFailures(fails, hookRoutes.everyRouteRecordsTheSameHits));
caseEnd();

caseBegin("hit-summary-is-bounded", "hooks/workflow-run-tests.js");
test("hit-summary-is-bounded", () => noNewFailures(fails, hookRoutes.hitSummaryIsBounded));
caseEnd();

caseBegin("a-replayed-outcome-records-the-same-hits", "hooks/workflow-run-tests/dispatch-outcome.js");
test("a-replayed-outcome-records-the-same-hits", () => noNewFailures(fails, hookRoutes.outcomeReplayIsIdempotent));
caseEnd();

caseBegin("hit-summary-is-sanitized", "hooks/workflow-run-tests.js");
test("hit-summary-is-sanitized", () => noNewFailures(fails, hookRoutes.hitSummaryIsSanitized));
caseEnd();

caseBegin("a-run-without-hits-records-none", "hooks/workflow-run-tests.js");
test("a-run-without-hits-records-none", () => noNewFailures(fails, hookRoutes.aRunWithoutHitsRecordsNone));
caseEnd();

caseBegin("log-tail-keeps-priority-lines", "bin/worker-dispatch/workers/test-runner.js");
test("log-tail-keeps-priority-lines", () => noNewFailures(fails, () => {
  workerTail.init();
  workerTail.logTailKeepsPriorityLines();
}));
caseEnd();

caseBegin("worker-collects-hits", "bin/worker-dispatch/workers/test-runner.js");
test("worker-collects-hits", () => noNewFailures(fails, workerTail.workerCollectsHits));
caseEnd();

caseBegin("worker-emits-missing-file-token", "bin/worker-dispatch/workers/test-runner.js");
test("worker-emits-missing-file-token", () => noNewFailures(fails, workerTail.workerEmitsMissingFileToken));
caseEnd();
