"use strict";
// #2853 — confirm-checkpoint's plan-stage audit check: a CONFIRM_{INTENT|OUTLINE|DETAIL} echo reaches
// the receipt check only when the stage's pre-confirm audit (hooks/lib/pre-confirm-audit.js) is
// settled CONTINUE / WARN or accepted. It runs before the receipt is consumed, so a deny keeps the
// receipt for the next attempt. The WORKFLOW_OFF marker skips it (ARP-EXBG user exit); the receipt
// check after it never reads that marker.

// Absence only: a path or fs failure throws to the caller, which denies (fail-closed).
function workflowStateExists(sid) {
  const { getStatePath } = require("../workflow-state/state-io");
  return require("fs").existsSync(getStatePath(sid));
}

const SKIP_REPORTER = "pre-confirm-audit-deny";

// recordStateless(sid, label) -> null: the no-state skip leaves one notice finding per session
// and label so the supervisor sees the unaudited CONFIRM. Never throws; a lost record never denies.
function recordStateless(sid, label) {
  try {
    const W = require("../lib/supervisor-state-writer");
    const detail = `pre-confirm audit skipped for ${label}: no workflow state file, so no audit could be armed`;
    const st = W.readState(sid);
    const seen = st && st.layer1 && Array.isArray(st.layer1.findings) &&
      st.layer1.findings.some((f) => f && f.reporter === SKIP_REPORTER && f.detail === detail);
    if (!seen) W.appendFinding(sid, { categories: ["workflow"], severity: "notice", detail, reporter: SKIP_REPORTER });
  } catch { /* fail-open: the record is diagnostics only */ }
  return null;
}

// auditDenyReason(sid, stage) -> the deny reason, or null when the receipt check may run.
function auditDenyReason(sid, stage) {
  const { stepForSuffix } = require("../workflow-state/plan-stage-table");
  const step = stepForSuffix(stage);
  if (!step) return null; // not a plan stage (CONFIRM_DOCS and the like)
  const label = `CONFIRM_${String(stage).toUpperCase()}`;
  const { describeAcceptanceCommand } = require("../lib/null-freshness/acceptance");
  if (!sid) return `[pre-confirm-audit] ${label} denied: the session id is unresolved, so the ${step} audit cannot be judged.`;
  if (require("../lib/session-markers").isWorkflowOff(sid)) return null;
  // No workflow state file: the session cannot run next-step --gate, so no audit can ever be armed
  // and WORKFLOW_OFF would be its only exit. Skip the check, as plan-approval-check does
  // (not-applicable), and record the skip as a notice finding. A state file that exists but fails
  // to read or judge stays fail-closed below.
  if (!workflowStateExists(sid)) return recordStateless(sid, label);
  const PCA = require("../lib/pre-confirm-audit");
  let j;
  try {
    j = PCA.judgeStage(sid, step, { cwd: process.cwd() }) || {};
  } catch (e) {
    let acc;
    try { acc = PCA.acceptedOnError(sid, step) || {}; } catch { acc = {}; }
    if (acc.accepted === true) return null;
    return `[pre-confirm-audit] ${label} denied: the ${step} audit could not be judged ` +
      `(${(e && e.message) || "unknown error"}), so the dialog stays closed. ${describeAcceptanceCommand(acc.runId)}`;
  }
  switch (j.state) {
    case "settled-continue":
    case "settled-warn":
    case "accepted":
      return null;
    case "unsettled":
      return `[pre-confirm-audit] ${label} denied: the ${step} audit of the current plan is not settled. ` +
        "Rerun next-step --gate and follow its GATE_ACTION (launch the supervisor-audit subagent on audit-wait), " +
        "then present the plan again.";
    case "settled-block":
      return `[pre-confirm-audit] ${label} denied: audit ${j.runId} returned BLOCK for the current plan. ` +
        `Show its findings to the user and revise the plan. ${describeAcceptanceCommand(j.runId)}`;
    case "cap-reached":
      return `[pre-confirm-audit] ${label} denied: the ${step} audit reached its run cap without a settled ` +
        `verdict on the current plan (last run ${j.runId || "none"}). ${describeAcceptanceCommand(j.runId)}`;
    default:
      return `[pre-confirm-audit] ${label} denied: unknown audit state ${j.state}. ${describeAcceptanceCommand(j.runId)}`;
  }
}

module.exports = { auditDenyReason };
