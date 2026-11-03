"use strict";
// Tests: hooks/workflow-mark.js, hooks/workflow-mark/review-tests-handler.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/glossary-accept-handler.js, hooks/workflow-mark/run-tests-accept-handler.js, hooks/workflow-mark/reset-handler.js
// Tags: TL2, hooks, workflow-mark, sentinel, output-channel, scope:issue-specific
// #2824 Steps 1-2: a refused sentinel always reaches the main conversation on the strong channel
// (exit 2 or {decision:"block"}, per emit.STRONG_CHANNEL) with a [NOT APPLIED] line and the state
// unchanged; INFO stays on the normal channel. The real hooks/workflow-mark.js is spawned per case.
// Dispatch only; the parts live in feature-2824-sentinel-refusal-output/.
// TL3 gap (what this test does NOT catch): whether Claude Code shows the strong channel on screen and
// to the model; tests/hooks/TL3-hook-posttooluse-output-channels.sh (RUN_TL3) probes that.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");

const restore = isolate();
// Loaded before make(): its provenance fixture pins the workflow dirs both fixtures then share.
const glossaryGrant = require("./feature-2824-sentinel-refusal-output/glossary-grant");
const X = require("./feature-2824-sentinel-refusal-output/fixture").make();
after(() => { X.cleanup(); restore(); });
const reviewTests = require("./feature-2824-sentinel-refusal-output/review-tests");
const reviewTestsRecovery = require("./feature-2824-sentinel-refusal-output/review-tests-recovery");
const markStep = require("./feature-2824-sentinel-refusal-output/mark-step");
const glossary = require("./feature-2824-sentinel-refusal-output/glossary-accept");
const runTests = require("./feature-2824-sentinel-refusal-output/run-tests-accept");
const reset = require("./feature-2824-sentinel-refusal-output/reset");
const dispatch = require("./feature-2824-sentinel-refusal-output/dispatch");

caseBegin("review-tests-refusals-use-the-strong-channel", "hooks/workflow-mark/review-tests-handler.js");
test("review-tests: missing fingerprint, LOOKSLIKE, short reason, nothing to accept -> strong channel", () => reviewTests.refusals(X));
caseEnd();

caseBegin("review-tests-scope-refusals-use-the-strong-channel", "hooks/workflow-mark/review-tests-handler.js");
test("review-tests: STALE_EVIDENCE, MANIFEST_UNAVAILABLE, failed state write -> strong channel", () => reviewTestsRecovery.refusals(X));
caseEnd();

caseBegin("review-tests-success-uses-the-normal-channel", "hooks/workflow-mark/review-tests-handler.js");
test("review-tests: accepted COMPLETE and WARNINGS_CLEARED stay on the normal channel", () => reviewTestsRecovery.applied(X));
caseEnd();

caseBegin("mark-step-refusals-use-the-strong-channel", "hooks/workflow-mark/mark-step-handler.js");
test("mark-step: forbidden, unknown, unapproved, no evidence, relayed kinds, failed write -> strong channel", () => markStep.refusals(X));
caseEnd();

caseBegin("mark-step-success-uses-the-normal-channel", "hooks/workflow-mark/mark-step-handler.js");
test("mark-step: an applied MARK_STEP stays on the normal channel", () => markStep.applied(X));
caseEnd();

caseBegin("glossary-accept-refusals-use-the-strong-channel", "hooks/workflow-mark/glossary-accept-handler.js");
test("glossary-accept: malformed, nothing-pending, failed state write -> strong channel", () => glossary.refusals(X));
caseEnd();

caseBegin("glossary-accept-success-uses-the-normal-channel", "hooks/workflow-mark/glossary-accept-handler.js");
test("glossary-accept: a grant recorded against a pending provenance block stays INFO", () => glossaryGrant.applied());
caseEnd();

caseBegin("parallel-glossary-accept-never-lost", "hooks/workflow-mark/glossary-accept-handler.js");
test("concurrent GLOSSARY_ACCEPTED: every grant is recorded or refused with a reason, never lost", () => glossaryGrant.parallel());
caseEnd();

caseBegin("run-tests-accept-refusals-use-the-strong-channel", "hooks/workflow-mark/run-tests-accept-handler.js");
test("run-tests-accept: short reason, no run, malformed, failed state write -> strong channel", () => runTests.refusals(X));
caseEnd();

caseBegin("run-tests-accept-success-uses-the-normal-channel", "hooks/workflow-mark/run-tests-accept-handler.js");
test("run-tests-accept: an accepted UNRUNNABLE run stays INFO and completes run_tests", () => runTests.applied(X));
caseEnd();

caseBegin("reset-refusals-use-the-strong-channel", "hooks/workflow-mark/reset-handler.js");
test("reset: malformed, short reason, unknown step, no state, prior gate -> strong channel", () => reset.refusals(X));
test("reset: a state write that fails (lock held) -> strong channel, reset-from failed", () => reset.failed(X));
caseEnd();

caseBegin("reset-success-says-steps-went-back-to-pending", "hooks/workflow-mark/reset-handler.js");
test("reset: an applied RESET_FROM reports the pending reset on the normal channel", () => reset.applied(X));
caseEnd();

caseBegin("dispatch-mixed-nonzero-subagent-are-unapplied", "hooks/workflow-mark.js");
test("dispatch: mixed command, non-zero echo, subagent sentinel -> strong channel", () => dispatch.unapplied(X));
caseEnd();

caseBegin("dispatch-applied-and-refused-are-told-apart", "hooks/workflow-mark.js");
test("dispatch: one applied + one refused sentinel in a chain -> strong channel, prefix only on the refused line", () => dispatch.mixed(X));
caseEnd();

caseBegin("dispatch-526-reset-without-session-is-info", "hooks/workflow-mark.js");
test("dispatch: #526 RESET_FROM without a session stays INFO; a non-sentinel command stays silent", () => dispatch.info(X));
caseEnd();
