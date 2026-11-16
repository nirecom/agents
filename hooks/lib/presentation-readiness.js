"use strict";
// #2961 — a plan stage's readiness to be presented: the one read-only judgment `next-step --gate`
// and the hooks share, so a turn is a plan presentation turn only when the gate would answer ask /
// proceed. It arms and spawns nothing; the gate reads only action / audit, the hooks only state.
//
// stageReadiness(sid, step, {gate}) -> {state, action, appr, audit}
//   state: ready | not-ready | approved | unknown — hooks treat ready / unknown as presentable.
//   action: proceed | ask, the gate's action before its audit branch.
//   audit: null (not audited) | {skipped} | {threw} | {j} | {judgeError, acc} | {judgeError, accError}.
// gate must be normalized by the caller (planGateState / planGateFromValue); a raw probe value
// would read clarify_intent's OFF as OFF.

function auditOf(sid, step) {
  try {
    if (require("./session-markers").isWorkflowOff(sid)) return { skipped: "workflow-off" };
    const PCA = require("./pre-confirm-audit");
    try {
      return { j: PCA.judgeStage(sid, step, { cwd: process.cwd() }) || {} };
    } catch (e) {
      const judgeError = String((e && e.message) || e);
      try {
        return { judgeError, acc: PCA.acceptedOnError(sid, step) || {} };
      } catch (e2) {
        return { judgeError, accError: String((e2 && e2.message) || e2) };
      }
    }
  } catch (e) {
    return { threw: String((e && e.message) || e) };
  }
}

function stateOf(audit, action) {
  if (audit.skipped) return "ready";
  if (audit.threw !== undefined) return "unknown";
  if (audit.judgeError !== undefined) return audit.acc && audit.acc.accepted === true ? "ready" : "unknown";
  return require("./pre-confirm-audit").auditAdmits(audit.j, action) === "admit" ? "ready" : "not-ready";
}

function stageReadiness(sid, step, opts) {
  const gate = opts && opts.gate;
  // Read through the module object so a preload that replaces the export is honored.
  const appr = require("../workflow-state/plan-approval-check").checkPlanApproval(sid, step, gate ? { gate } : undefined);
  const action = appr.verdict === "approved" ? "proceed" : "ask";
  if (appr.verdict === "approved" && !appr.waived) return { state: "approved", action, appr, audit: null };
  const audit = auditOf(sid, step);
  const known = appr.verdict === "approved" || appr.verdict === "unapproved";
  return { state: known ? stateOf(audit, action) : "unknown", action, appr, audit };
}

// readinessForFrom(gateFor) -> (sid, step) -> state, computed once per sid and step on gateFor's
// (normalized) gate; a throw reads unknown, which keeps the legacy behaviour.
function readinessForFrom(gateFor) {
  const memo = new Map();
  return (sid, step) => {
    const key = `${sid}\u0000${step}`;
    if (!memo.has(key)) {
      let state;
      try { state = stageReadiness(sid, step, { gate: gateFor(step) }).state; } catch (_) { state = "unknown"; }
      memo.set(key, state);
    }
    return memo.get(key);
  };
}

// presentable(state) -> whether a turn that wrote or showed the stage is a plan presentation turn.
const presentable = (state) => state === "ready" || state === "unknown";

module.exports = { stageReadiness, readinessForFrom, presentable };
