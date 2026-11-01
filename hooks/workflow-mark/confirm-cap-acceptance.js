"use strict";
// #2873 — after a CONFIRM_{INTENT|OUTLINE|DETAIL} Allow is recorded as the plan approval, record the
// same Allow as the acceptance of the stage's pre-confirm audit when the stage is past its audit run
// cap with a terminal WARN / CONTINUE last run (hooks/lib/pre-confirm-audit.js isCapConfirmAcceptable).
// Skipped under WORKFLOW_OFF (the gate skipped the audit) and when the stage's CONFIRM gate is OFF
// (no dialog, so the echo is no Allow). A refusal is shown; the plan approval stands either way.

const { sanitizeLine } = require("../lib/output-sanitize");
const { rowFor } = require("../workflow-state/plan-stage-table");

const REPORTER = "workflow-mark:confirm-cap-acceptance";
const SUMMARY_MAX = 200;

function defaultDeps() {
  const PCA = require("../lib/pre-confirm-audit");
  return {
    judgeStage: PCA.judgeStage,
    isWorkflowOff: require("../lib/session-markers").isWorkflowOff,
    planGateState: require("../lib/confirm-gate/plan-gate").planGateState,
    record: require("../lib/supervisor-block-override").recordStageCapAcceptance,
  };
}

// recordOnConfirm({ sessionId, step, summary, repoCwd, pushMessage }, deps?) -> undefined
function recordOnConfirm(ctx, deps) {
  const d = Object.assign(defaultDeps(), deps || {});
  const { sessionId, step, pushMessage } = ctx;
  const row = rowFor(step);
  if (!row) return;
  const label = `CONFIRM_${row.suffix.toUpperCase()}`;
  const notRecorded = (code, message) => pushMessage(
    `workflow-mark: pre-confirm audit acceptance NOT recorded — ${code}: ${message} ` +
      `The ${step} approval itself is recorded and the workflow continues; show this line to the user.`);

  if (d.isWorkflowOff(sessionId)) return;
  try {
    if (d.planGateState(row.suffix) === "OFF") return;
  } catch {
    return;
  }
  let j;
  try {
    j = d.judgeStage(sessionId, step, { cwd: ctx.repoCwd }) || {};
  } catch (e) {
    notRecorded("judge-failed", (e && e.message) || "unknown error");
    return;
  }
  const { isCapConfirmAcceptable, triggerForPlanStep } = require("../lib/pre-confirm-audit");
  if (!isCapConfirmAcceptable(j)) return;

  const reason = `${label} Allow at the audit run cap: ${sanitizeLine(ctx.summary, SUMMARY_MAX)}`;
  let r;
  try {
    r = d.record(sessionId, { step, runId: j.runId, reason, actor: label, reporter: REPORTER });
  } catch (e) {
    r = { ok: false, code: "record-failed", message: (e && e.message) || "unknown error" };
  }
  if (!r || r.ok !== true) {
    notRecorded((r && r.code) || "unknown", (r && r.message) || "unknown error");
    return;
  }
  const tr = (triggerForPlanStep(step) || {}).tr_id;
  pushMessage(`workflow-mark: pre-confirm audit ${j.verdict} of ${j.runId} (${tr}) accepted by the ${label} Allow ` +
    "(audit run cap reached).");
}

module.exports = { recordOnConfirm };
