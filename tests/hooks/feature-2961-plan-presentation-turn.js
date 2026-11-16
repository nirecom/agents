#!/usr/bin/env node
// tests/hooks/feature-2961-plan-presentation-turn.js
// Tests: hooks/lib/presentation-readiness.js, hooks/lib/pre-confirm-audit.js, bin/workflow/lib/next-step/gate-mode.js, hooks/lib/presentation-turn.js, hooks/show-plan-link.js, hooks/lib/plan-link.js
// Tags: TL1, TL2, hooks, plan-presentation-turn, pre-confirm-audit, presentation-readiness, plan-link, show-plan-link, subagent, scope:issue-specific
// TL3 gap: a real subagent (outline-planner) writing the plan inside a live Claude Code turn, and a
// real plan-sync push; here the hook input carries agent_id by hand and the sync result is injected.
// #2961: a plan presentation turn is a turn whose stage is ready to confirm. stageReadiness reads the
// approval and the pre-confirm audit once for the gate and the hooks; a mid-turn write gets the
// INTERIM duty instead of a link-line duty. The Stop cases live in ./feature-2961-plan-presentation-turn-stop.js.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2961pt-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.PLAN_LANG;
delete process.env.CONV_LANG;
process.chdir(SCRATCH);
afterAll(() => {
  process.chdir(os.tmpdir());
  restore();
  try { fs.rmSync(SCRATCH, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const RC = require("./feature-2961-plan-presentation-turn/readiness-cases");
const AW = require("./feature-2961-plan-presentation-turn/after-write-cases");
const SA = require("./feature-2961-plan-presentation-turn/subagent-cases");

caseBegin("audit-admits-table", "hooks/lib/pre-confirm-audit.js");
test("auditAdmits: settled-continue / settled-warn / accepted admit, unsettled arms, cap-reached admits only on ask, the rest close", RC.admitsTable);
caseEnd();

caseBegin("stage-readiness-states", "hooks/lib/presentation-readiness.js");
test("stageReadiness: approved and not waived is approved with no audit read", RC.approvedNotWaived);
test("stageReadiness: a waived (OFF) outline still follows its audit", RC.waivedFollowsAudit);
test("stageReadiness: unapproved x each audit state on the ON gate", RC.unapprovedByAuditState);
test("stageReadiness: cap-reached x ask / proceed, and an acceptance past the cap", RC.capReached);
test("stageReadiness: WORKFLOW_OFF skips the audit and is ready", RC.workflowOff);
test("stageReadiness: judgeStage throws -> accepted on error ready, otherwise unknown", RC.judgeThrows);
test("stageReadiness: skipped / not-applicable / unknown verdicts are unknown, the gate still asks", RC.otherVerdicts);
caseEnd();

caseBegin("gate-and-readiness-agree", "bin/workflow/lib/next-step/gate-mode.js");
test("next-step --gate and stageReadiness read one classification", RC.gateAgrees);
caseEnd();

caseBegin("intent-off-reads-on", "hooks/lib/presentation-turn.js");
test("CONFIRM_INTENT=off: probesFor().gateFor reads ON and readinessFor judges on it", RC.intentOffReadsOn);
caseEnd();

caseBegin("after-write-interim-duty", "hooks/lib/plan-link.js");
test("plan-link exports INTERIM_DUTY and INTERIM_DUTY_ONE, neither asking for a link line", AW.interimExported);
test("renderModelContext: an entry without readiness renders as before", AW.legacyWithoutReadiness);
test("renderModelContext: all entries in a mid-turn print only INTERIM_DUTY, no PUBLISH_NOTE", AW.allInterim);
test("renderModelContext: ready and unknown keep the gate's duty", AW.readyAndUnknownKeepLegacy);
test("renderModelContext: mixed gates x mixed readiness print one _ONE text per entry", AW.mixedPerEntry);
caseEnd();

caseBegin("after-write-readiness-from-the-hook", "hooks/show-plan-link.js");
test("emitForArtifacts: an unsettled outline write is a mid-turn, a settled one keeps the ON duty", AW.emitByReadiness);
test("emitForArtifacts: intent approved, outline ready ON, detail ready OFF in one write", AW.emitMixed);
test("emitForArtifacts: CONFIRM_INTENT=off still gives a settled intent the ON duty", AW.emitIntentOff);
caseEnd();

caseBegin("subagent-write-mid-turn", "hooks/show-plan-link.js");
test("a subagent's plan write: marker under the main sid, INTERIM duty, no Stop duty until the audit settles", SA.subagentMidTurnThenPresentation);
caseEnd();
