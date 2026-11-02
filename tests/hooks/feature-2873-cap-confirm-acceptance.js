"use strict";
// tests/hooks/feature-2873-cap-confirm-acceptance.js
// Tests: hooks/lib/pre-confirm-audit.js, bin/workflow/lib/next-step/gate-mode.js, hooks/confirm-checkpoint/pre-confirm-audit-deny.js, hooks/lib/supervisor-block-override.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/lib/null-freshness/acceptance.js, hooks/workflow-mark/confirm-cap-acceptance.js
// Tags: TL2, scope:issue-specific, supervisor-audit, pre-confirm-audit, confirm-gate, workflow-mark, run-cap, TL1, acceptance
// #2873: a plan stage whose pre-confirm audit hit its run cap with a WARN / CONTINUE last run lets
// the user decide at the CONFIRM: the gate asks, the deny opens, and the Allow records the
// acceptance of that run (actor CONFIRM_<STAGE>). BLOCK, a non-terminal last run, and a stage whose
// CONFIRM gate is OFF keep the VERDICT_ACCEPTED path. Real writers, real gate CLI, in-process handler.
// TL3 gap: the CONFIRM echo here is driven through the PostToolUse handler in process; whether the
// real Claude Code permission dialog shows the GATE_AUDIT_SUMMARY line before the Allow is only seen
// in a live session.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");

const restore = isolate();
after(restore);
const C = require("./feature-2873-cap-confirm-acceptance/cases");

caseBegin("cap-reached judgment carries the last run's verdict and terminality", "hooks/lib/pre-confirm-audit.js");
test("cap-reached judgment carries the last run's verdict and terminality", () => C.judgeCarriesVerdict());
caseEnd();

caseBegin("gate asks at the cap for WARN and CONTINUE and blocks BLOCK", "bin/workflow/lib/next-step/gate-mode.js");
test("gate asks at the cap for WARN and CONTINUE and blocks BLOCK", () => C.gateAnswers());
caseEnd();

caseBegin("CONFIRM deny opens at the cap for WARN and CONTINUE only", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("CONFIRM deny opens at the cap for WARN and CONTINUE only", () => C.denyAnswers());
caseEnd();

caseBegin("CONFIRM Allow records one acceptance with actor CONFIRM_STAGE", "hooks/workflow-mark/confirm-approval-handler.js");
test("CONFIRM Allow records one acceptance with actor CONFIRM_STAGE", () => C.allowRecords());
caseEnd();

caseBegin("recorded acceptance releases judgeStage and acceptedOnError", "hooks/lib/null-freshness/acceptance.js");
test("recorded acceptance releases judgeStage and acceptedOnError", () => C.recordReleases());
caseEnd();

caseBegin("a repeated CONFIRM Allow records nothing more", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("a repeated CONFIRM Allow records nothing more", () => C.allowIsIdempotent());
caseEnd();

caseBegin("non-terminal last run keeps the deny closed at the cap", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("non-terminal last run keeps the deny closed at the cap", () => C.nonTerminalDeny());
caseEnd();

caseBegin("non-terminal last run keeps the gate on audit-block at the cap", "bin/workflow/lib/next-step/gate-mode.js");
test("non-terminal last run keeps the gate on audit-block at the cap", () => C.nonTerminalGate());
caseEnd();

caseBegin("CONFIRM OFF keeps outline and detail on audit-block and intent asking", "bin/workflow/lib/next-step/gate-mode.js");
test("CONFIRM OFF keeps outline and detail on audit-block and intent asking", () => C.confirmOffGate());
caseEnd();

caseBegin("CONFIRM OFF records no acceptance for outline and detail", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("CONFIRM OFF records no acceptance for outline and detail", () => C.confirmOffRecord());
caseEnd();

caseBegin("WORKFLOW_OFF marker keeps the default deps from recording", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("WORKFLOW_OFF marker keeps the default deps from recording", () => C.workflowOffRecordsNothing());
caseEnd();

caseBegin("a failed plan approval records no acceptance", "hooks/workflow-mark/confirm-approval-handler.js");
test("a failed plan approval records no acceptance", () => C.approvalFailureRecordsNothing());
caseEnd();

// T3/T4: recordStageCapAcceptance on seeded supervisor state.
const SC = require("./feature-2873-cap-confirm-acceptance/stage-cases");

caseBegin("lastStageRun is exported and picks the stage's own last run", "hooks/lib/pre-confirm-audit.js");
test("lastStageRun is exported and picks the stage's own last run", () => SC.lastStageRunExported());
caseEnd();

caseBegin("stage acceptance records the stage run behind a later TR4 run", "hooks/lib/supervisor-block-override.js");
test("stage acceptance records the stage run behind a later TR4 run", () => SC.recordsHiddenStageRun());
caseEnd();

caseBegin("stage acceptance releases acceptedOnError and judgeStage", "hooks/lib/pre-confirm-audit.js");
test("stage acceptance releases acceptedOnError and judgeStage", () => SC.acceptanceReleasesStage());
caseEnd();

caseBegin("a reviewed-verdict refusal of a plan-stage run points at the CONFIRM Allow", "hooks/lib/supervisor-block-override.js");
test("a reviewed-verdict refusal of a plan-stage run points at the CONFIRM Allow", () => SC.reviewedRefusalGuidesToConfirm());
caseEnd();

caseBegin("stage acceptance refusals name their code and write nothing", "hooks/lib/supervisor-block-override.js");
test("stage acceptance refusals name their code and write nothing", () => SC.refusalsWriteNothing());
caseEnd();

caseBegin("a run mixing a plan stage and TR5 keeps the TR5 verdict set", "hooks/lib/supervisor-block-override.js");
test("a run mixing a plan stage and TR5 keeps the TR5 verdict set", () => SC.mixedTrRunKeepsTr5Set());
caseEnd();

// T5: recordOnConfirm with stubbed deps.
const HC = require("./feature-2873-cap-confirm-acceptance/handler-cases");

caseBegin("recordOnConfirm records an acceptable cap with actor CONFIRM_STAGE", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm records an acceptable cap with actor CONFIRM_STAGE", () => HC.acceptableCapRecords());
caseEnd();

caseBegin("recordOnConfirm reason is one sanitized line capped at 200 summary characters", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm reason is one sanitized line capped at 200 summary characters", () => HC.reasonIsOneCappedLine());
caseEnd();

caseBegin("recordOnConfirm shows a refused record with its code and the approval note", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm shows a refused record with its code and the approval note", () => HC.refusedRecordIsShown());
caseEnd();

caseBegin("recordOnConfirm reports judge-failed and records nothing", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm reports judge-failed and records nothing", () => HC.throwingJudgeIsShown());
caseEnd();

caseBegin("recordOnConfirm records nothing under WORKFLOW_OFF or a CONFIRM gate OFF", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm records nothing under WORKFLOW_OFF or a CONFIRM gate OFF", () => HC.offOrGateOffRecordsNothing());
caseEnd();

caseBegin("recordOnConfirm records nothing for a judgment that is not an acceptable cap", "hooks/workflow-mark/confirm-cap-acceptance.js");
test("recordOnConfirm records nothing for a judgment that is not an acceptable cap", () => HC.otherJudgmentsRecordNothing());
caseEnd();
