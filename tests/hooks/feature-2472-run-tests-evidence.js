#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/record-step-verdict/run-tests-evidence.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-gate.js
// Tags: TL2, hooks, run-tests, workflow-state, completion-evidence, dispatch-outcome, scope:issue-specific
// #2472 T5: run_tests completes only on run evidence, on every gate. Refusal without evidence
// (no-run-evidence), already on every recorded-complete shape, the ingest-pending refusal and
// its show-dispatch-outcome.sh recovery, and the exits that stay open (skipped tombstone,
// docs-only NOT_NEEDED, WORKFLOW_OFF). Parts live in feature-2472-run-tests-evidence/.

// TL3 gap: Claude Code itself does not deliver the PostToolUse call after show-dispatch-outcome.sh;
// the test wraps the script's real stdout in the hook's input JSON.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2472-evidence");
const gates = require("./feature-2472-run-tests-evidence/gates");
const ingest = require("./feature-2472-run-tests-evidence/ingest");
const exits = require("./feature-2472-run-tests-evidence/exits");

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

caseBegin("every-gate-refuses-completion-without-run-evidence", "hooks/workflow-state/record-step-verdict.js");
test("every-gate-refuses-completion-without-run-evidence", () => noNewFailures(fails, gates.refusesWithoutEvidence));
caseEnd();

caseBegin("every-gate-answers-already-on-a-recorded-complete", "hooks/workflow-state/record-step-verdict.js");
test("every-gate-answers-already-on-a-recorded-complete", () => noNewFailures(fails, gates.alreadyOnRecordedComplete));
caseEnd();

caseBegin("mark-step-sentinel-relays-the-refusal", "hooks/workflow-mark/mark-step-handler.js");
test("mark-step-sentinel-relays-the-refusal", () => noNewFailures(fails, gates.markStepHandlerRelaysRefusal));
caseEnd();

caseBegin("advance-cli-exits-non-zero-without-evidence", "hooks/workflow-state/record-step-verdict.js");
test("advance-cli-exits-non-zero-without-evidence", () => noNewFailures(fails, gates.advanceCliRefuses));
caseEnd();

caseBegin("run-tests-evidence-module-owns-the-rule", "hooks/workflow-state/record-step-verdict/run-tests-evidence.js");
test("run-tests-evidence-module-owns-the-rule", () => noNewFailures(fails, gates.evidenceModuleContract));
caseEnd();

caseBegin("ingest-pending-outcome-is-refused-then-recovered", "hooks/workflow-run-tests/dispatch-outcome.js");
test("ingest-pending-outcome-is-refused-then-recovered", () => noNewFailures(fails, ingest.ingestPendingFlow));
caseEnd();

caseBegin("skipped-transition-writes-the-null-tombstone", "hooks/workflow-state/record-step-verdict.js");
test("skipped-transition-writes-the-null-tombstone", () => noNewFailures(fails, exits.skippedWritesTombstone));
caseEnd();

caseBegin("docs-only-not-needed-passes-after-a-refusal", "hooks/workflow-mark/not-needed-handlers.js");
test("docs-only-not-needed-passes-after-a-refusal", () => noNewFailures(fails, exits.docsOnlyNotNeededAfterRefusal));
caseEnd();

caseBegin("workflow-off-commit-passes-after-a-refusal", "hooks/workflow-gate.js");
test("workflow-off-commit-passes-after-a-refusal", () => noNewFailures(fails, exits.workflowOffCommitAfterRefusal));
caseEnd();

caseBegin("unrunnable-accepted-after-a-refusal-then-already", "hooks/workflow-state/record-step-verdict.js");
test("unrunnable-accepted-after-a-refusal-then-already", () => noNewFailures(fails, exits.unrunnableAcceptedAfterRefusal));
caseEnd();

caseBegin("mark-step-refuses-ingest-pending-then-passes-after-ingest", "hooks/workflow-mark/mark-step-handler.js");
test("mark-step-refuses-ingest-pending-then-passes-after-ingest", () => noNewFailures(fails, ingest.markStepIngestPendingFlow));
caseEnd();

caseBegin("fixture-run-launches-with-node-unless-node-false", "tests/lib/run-tests-outcome-fixture.js");
test("fixture-run-launches-with-node-unless-node-false", () => noNewFailures(fails, ingest.launchInterpreterFlow));
caseEnd();
