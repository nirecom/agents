"use strict";
// #2853 — the plan-stage pre-confirm audit (TR1 intent / TR2 outline / TR3 detail).
// The stage's CONFIRM gate (`next-step --gate`) and the confirm-checkpoint hook both read the
// stage's audit state here, so the gate that arms the run and the hook that guards the dialog
// judge the same plan with the same keys. Ledger, keys and acceptance:
// docs/architecture/claude-code/supervisor-audit-ledger.md "Pre-confirm audit (TR1–TR3)".
//
// judgeStage(sid, step, ctx) -> { state, runId, verdict, summary }; state is one of
//   settled-continue | settled-warn | settled-block | accepted | unsettled | cap-reached.
// It throws when a plan-artifact key computation fails: callers fail closed via acceptedOnError.

const fp = require("./diff-fingerprint");
const triggers = require("./audit-triggers");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { findStageAcceptance, safeRunId } = require("./null-freshness/acceptance");
const { formatAgentModelLine } = require("./role-model");

// A stage's audit runs at most this many times before the gate stops arming and asks the user.
const AUDIT_RUN_CAP = 3;
const VERDICT_RANK = { CONTINUE: 0, WARN: 1, BLOCK: 2 };

const STAGE_TRIGGER = new Map(
  triggers.TRIGGERS.filter((t) => t.kind === "pre-confirm").map((t) => [t.step, t])
);

function triggerForPlanStep(step) {
  return STAGE_TRIGGER.get(step) || null;
}

function requireTrigger(step) {
  const t = triggerForPlanStep(step);
  if (!t) throw new Error(`not a plan stage: ${step}`);
  return t;
}

function planScope(sid, ctx) {
  const c = ctx || {};
  return {
    plansDir: c.plans_dir || getWorkflowPlansDir(),
    planSessionId: c.plan_session_id || sid,
  };
}

function readAudit(sid) {
  const { readState } = require("./supervisor-state-writer");
  const st = readState(sid);
  return (st && st.audit && typeof st.audit === "object") ? st.audit : {};
}

const ledgerOf = (audit) => (Array.isArray(audit.ledger) ? audit.ledger.filter((e) => e && typeof e === "object") : []);
const countOf = (audit, tr) => {
  const n = audit.audit_run_counts && audit.audit_run_counts[tr];
  return Number.isInteger(n) ? n : 0;
};

// The stage's current keys, computed the way the arm writer records them: one per sub-check
// (input_key) and one over the union of the trigger's artifacts (trigger_input_keys[TR]).
// An absent plan artifact yields a null key (complete === false): no terminal run can match it, so
// the stage stays unsettled and arms. A key computation that throws propagates to the caller.
function currentKeys(trigger, scope) {
  const keyOf = (artifacts) => {
    const k = fp.computeArtifactKey(scope.plansDir, scope.planSessionId, artifacts);
    return typeof k === "string" && k !== "" ? k : null;
  };
  const subKeys = {};
  for (const id of trigger.sub_checks) {
    const spec = triggers.SUB_CHECKS[id];
    subKeys[id] = keyOf(spec ? spec.artifacts : []);
  }
  const union = [];
  for (const id of trigger.sub_checks) {
    for (const a of (triggers.SUB_CHECKS[id] || { artifacts: [] }).artifacts) if (!union.includes(a)) union.push(a);
  }
  const stageKey = keyOf(union);
  const complete = stageKey !== null && trigger.sub_checks.every((id) => subKeys[id] !== null);
  return { subKeys, stageKey, complete };
}

// For every sub-check, the newest terminal run judged at its current key; null when one is missing.
function settledRuns(audit, trigger, subKeys) {
  const entries = ledgerOf(audit);
  const picked = [];
  for (const id of trigger.sub_checks) {
    let hit = null;
    for (let i = entries.length - 1; i >= 0 && !hit; i--) {
      const e = entries[i];
      if (e.outcome !== "terminal" || !Array.isArray(e.sub_checks) || !e.sub_checks.includes(id)) continue;
      if (e.input_key && e.input_key[id] === subKeys[id]) hit = e;
    }
    if (!hit) return null;
    picked.push(hit);
  }
  return picked;
}

// The heaviest verdict among the picked runs (BLOCK > WARN > CONTINUE); the later run wins a tie.
function heaviest(runs) {
  let best = null;
  for (const r of runs) {
    const rank = VERDICT_RANK[r.verdict];
    if (rank === undefined) continue;
    if (!best || rank >= VERDICT_RANK[best.verdict]) best = r;
  }
  return best;
}

function lastStageRun(audit, tr) {
  const entries = ledgerOf(audit);
  for (let i = entries.length - 1; i >= 0; i--) {
    if (Array.isArray(entries[i].tr_ids) && entries[i].tr_ids.includes(tr)) return entries[i];
  }
  return null;
}

function acceptanceTr(run, tr) {
  const trs = Array.isArray(run.tr_ids) ? run.tr_ids : [];
  return trs.includes(tr) ? tr : trs[0];
}

// The armed run in the slot when it judges this stage at its current keys.
function currentInFlightRun(audit, trigger, subKeys) {
  if (audit.audit_phase !== "pending" && audit.audit_phase !== "in_progress") return null;
  const id = audit.audit_run_id;
  const run = ledgerOf(audit).filter((e) => e.id === id).pop();
  if (!run || !Array.isArray(run.tr_ids) || !run.tr_ids.includes(trigger.tr_id)) return null;
  const keys = run.input_key || {};
  return trigger.sub_checks.every((sc) => keys[sc] === subKeys[sc]) ? run : null;
}

const out = (state, run, verdict, extra) =>
  Object.assign({ state, runId: run ? run.id : null, verdict: verdict || null, summary: (run && run.verdict_summary) || null }, extra || {});

function judgeStage(sid, step, ctx) {
  const trigger = requireTrigger(step);
  const tr = trigger.tr_id;
  const { subKeys, stageKey, complete } = currentKeys(trigger, planScope(sid, ctx));
  const audit = readAudit(sid);
  const capped = countOf(audit, tr) >= AUDIT_RUN_CAP;

  const runs = complete ? settledRuns(audit, trigger, subKeys) : null;
  if (runs) {
    const top = heaviest(runs);
    if (!top) throw new Error("settled runs carry no verdict");
    if (top.verdict === "CONTINUE") return out("settled-continue", top, "CONTINUE");
    // The run judged the current plan, so its acceptance needs no key comparison.
    if (findStageAcceptance(audit, acceptanceTr(top, tr), top.id)) return out("accepted", top, top.verdict);
    return out(top.verdict === "WARN" ? "settled-warn" : "settled-block", top, top.verdict);
  }

  const last = lastStageRun(audit, tr);
  const acc = last ? findStageAcceptance(audit, tr, last.id) : null;
  // Past the cap the acceptance stands on any plan; below it, only on the plan it accepted.
  if (acc && (capped || (stageKey !== null && acc.trigger_key === stageKey))) return out("accepted", last, acc.verdict);

  const inFlight = currentInFlightRun(audit, trigger, subKeys);
  if (inFlight) return out("unsettled", inFlight, null, { inFlight: true });
  if (capped) return out("cap-reached", last, last && last.verdict);
  return out("unsettled", null, null);
}

// armStage(sid, step, ctx) -> the armAuditRun result. Never arms past the cap, and returns the
// in-flight run as-is when it already judges the current plan, so a rerun gate counts nothing.
function armStage(sid, step, ctx) {
  const trigger = requireTrigger(step);
  const tr = trigger.tr_id;
  const scope = planScope(sid, ctx);
  const { subKeys } = currentKeys(trigger, scope);
  const audit = readAudit(sid);
  const inFlight = currentInFlightRun(audit, trigger, subKeys);
  if (inFlight) return { ok: true, audit_run_id: inFlight.id, run_id: inFlight.id, reused: true };
  if (countOf(audit, tr) >= AUDIT_RUN_CAP) return { ok: false, audit_run_id: null, run_id: null, reason: "cap-reached" };
  const { armAuditRun } = require("./supervisor-state-writer/audit-run");
  return armAuditRun(sid, {
    tr_ids: [tr], cause: triggers.preConfirmCause(step), count_tr: tr,
    cwd: (ctx && ctx.cwd) || undefined, plans_dir: scope.plansDir, plan_session_id: scope.planSessionId,
    launch_shown: true, supersede_unsettled: true,
  });
}

// acceptedOnError(sid, step) -> { accepted, runId }: the judgment's error exit. Reads only the
// state file, never a plan artifact, so it answers when the keys cannot be computed.
function acceptedOnError(sid, step) {
  const trigger = requireTrigger(step);
  const audit = readAudit(sid);
  const last = lastStageRun(audit, trigger.tr_id);
  if (!last) return { accepted: false, runId: null };
  return { accepted: Boolean(findStageAcceptance(audit, trigger.tr_id, last.id)), runId: last.id };
}

// formatLaunch(runId, step) -> the instruction shown with audit-wait.
function formatLaunch(runId, step) {
  const t = triggerForPlanStep(step);
  const label = t ? `${step} (${t.tr_id})` : String(step);
  return [
    `[EM Supervisor] ${label} pre-confirm audit armed: ${safeRunId(runId)}.`,
    "Run agents/supervisor-audit.md as a subagent, then rerun next-step --gate and follow its GATE_ACTION.",
    formatAgentModelLine("reviewer"),
  ].join(" ");
}

module.exports = {
  AUDIT_RUN_CAP, triggerForPlanStep, judgeStage, armStage, acceptedOnError, formatLaunch,
};
