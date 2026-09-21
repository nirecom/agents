"use strict";

// #2256 S6-b / S6-c — the Stop-hook audit-arm orchestrator (authority: detail.md
// S6-b/S6-c). Folds the candidate array from collectAuditCandidates into at most
// one armAuditRun (one identity/Stop). Edge triggers' own sub_checks are always
// judged (fired transition = fresh input, S4-a); every other sub-check is kept
// only when unsettled (isSubCheckSettled, <sub_check_id>@<input_key>) inside the
// earliest_tr window. TR6 (level, no transition) is fully settle-filtered, which
// keeps a standing cumSev=error from re-auditing on every Stop (S6-a).

const { collectAuditCandidates } = require("./collect-audit-triggers");
const { computeFreshnessKey } = require("../lib/diff-fingerprint");
const {
  armAuditRun,
  consumeTransitions,
  inputKeyForSubCheck,
} = require("../lib/supervisor-state-writer/audit-run");
const { isSubCheckSettled } = require("../lib/audit-ledger");
const { SUB_CHECKS, ALL_SUB_CHECK_IDS } = require("../lib/audit-triggers");
let getWorkflowPlansDir = null;
try { ({ getWorkflowPlansDir } = require("../lib/workflow-plans-dir")); } catch (_) { /* optional */ }

const TR_RANK = { TR1: 1, TR2: 2, TR3: 3, TR4: 4, TR5: 5, TR6: 6 };

// Fold the candidate array into the merged identity fields plus the classifier
// state the judgment set needs (which sub-checks are always in, how far the
// earliest_tr window reaches, whether the level trigger is present).
function coalesce(candidates) {
  const trIds = [];
  const transitions = [];
  const causes = [];
  const ownAlways = new Set();
  let maxEdgeRank = 0;
  let levelPresent = false;

  for (const c of candidates) {
    if (!c || typeof c !== "object") continue;
    if (c.tr_id && !trIds.includes(c.tr_id)) trIds.push(c.tr_id);
    if (typeof c.transition === "string" && c.transition && !transitions.includes(c.transition)) {
      transitions.push(c.transition);
    }
    if (typeof c.cause === "string" && c.cause && !causes.includes(c.cause)) causes.push(c.cause);

    if (c.tr_id === "TR6") {
      // Level trigger: sub_checks are dedup-filtered (not added to ownAlways);
      // it does widen the window to every sub-check.
      levelPresent = true;
      continue;
    }
    for (const s of Array.isArray(c.sub_checks) ? c.sub_checks : []) ownAlways.add(s);
    const rank = TR_RANK[c.tr_id] || 0;
    if (rank > maxEdgeRank) maxEdgeRank = rank;
  }

  return { trIds, transitions, causes, ownAlways, maxEdgeRank, levelPresent };
}

// Exclude recurrence-patterns when freshness_key is null (artifact-side or code-
// side): its inputKeyForSubCheck returns null, isSubCheckSettled is always false
// (fail-closed), and including it creates an infinite re-arm loop (#2360).
function filterNullKeySubChecks(ids, freshness) {
  if (freshness && freshness.freshness_key == null) {
    return ids.filter((id) => id !== "recurrence-patterns");
  }
  return ids;
}

// The coalesced judgment set: every edge trigger's own sub_checks (always), plus
// every other not-yet-settled sub-check inside the earliest_tr window.
function buildJudgmentSet(audit, coalesced, freshness, planSessionId, plansDir) {
  const { ownAlways, maxEdgeRank, levelPresent } = coalesced;
  return filterNullKeySubChecks(ALL_SUB_CHECK_IDS, freshness).filter((id) => {
    if (ownAlways.has(id)) return true;
    const spec = SUB_CHECKS[id];
    if (!spec) return false;
    const inScope = levelPresent || TR_RANK[spec.earliest_tr] <= maxEdgeRank;
    if (!inScope) return false;
    const key = inputKeyForSubCheck(id, spec, freshness, planSessionId, plansDir);
    // key === null (git unavailable / artifact missing) → isSubCheckSettled
    // returns false → the sub-check is judged (fail-closed, S6-b).
    return !isSubCheckSettled(audit, id, key);
  });
}

// Fold the candidate array into at most one arm. Returns one of:
//   { action: "none" }                              — nothing to consider
//   { action: "consume", transitions }              — all in-scope sub-checks
//                                                      already settled (no-op)
//   { action: "arm", ok, run_id, sub_checks, ... }  — a run was armed
function armFromCandidates(sessionId, candidates, ctx) {
  if (!Array.isArray(candidates) || candidates.length === 0) return { action: "none" };
  const audit = (ctx && ctx.state && ctx.state.audit) || {};
  const plansDir = ctx.plansDir;
  const planSessionId = ctx.planSessionId;

  let freshness;
  try {
    freshness = computeFreshnessKey(ctx.cwd, plansDir, planSessionId);
  } catch (_) {
    freshness = { input_version: null, artifact_keys: {}, freshness_key: null };
  }

  const coalesced = coalesce(candidates);
  const judgmentSet = buildJudgmentSet(audit, coalesced, freshness, planSessionId, plansDir);

  if (judgmentSet.length === 0) {
    // No-op: every in-scope sub-check is already settled. Consume the fired
    // transitions so the same edge never re-arms next Stop (S6-b).
    if (coalesced.transitions.length > 0) {
      try { consumeTransitions(sessionId, coalesced.transitions); } catch (_) {}
    }
    return { action: "consume", transitions: coalesced.transitions };
  }

  const cause = coalesced.causes.join(" + ");
  const result = armAuditRun(sessionId, {
    tr_ids: coalesced.trIds,
    sub_checks: judgmentSet,
    transitions: coalesced.transitions,
    cause,
    cwd: ctx.cwd,
    plans_dir: plansDir,
    plan_session_id: planSessionId,
  });

  return {
    action: "arm",
    ok: !!(result && result.ok === true),
    run_id: (result && (result.run_id || result.audit_run_id)) || null,
    sub_checks: (result && result.sub_checks) || judgmentSet,
    scope_drift: (result && result.scope_drift) || null,
    tr_ids: coalesced.trIds,
    cause,
  };
}

// The S4-d block message: names the armed run-id and states supervisor-audit may
// be dispatched in the same turn as /run-tests, without waiting for
// review_security. Scope drift, when present, is listed for the agent.
function formatAuditArmReason(armInfo, meta) {
  const runId = (armInfo && armInfo.run_id) || "<none>";
  const subChecks = armInfo && Array.isArray(armInfo.sub_checks) ? armInfo.sub_checks.join(", ") : "";
  const lines = [
    "[EM Supervisor] Audit mode strategic review triggered (pre-merge shift-left arm).",
    `Run ID: ${runId}`,
    `Trigger: ${(armInfo && armInfo.cause) || "<none>"}`,
  ];
  if (subChecks) lines.push(`Sub-checks: ${subChecks}`);
  const drift = armInfo && armInfo.scope_drift;
  if (Array.isArray(drift) && drift.length > 0) {
    lines.push(`Scope drift (undeclared files): ${drift.join(", ")}`);
  }
  lines.push(
    "",
    `Session ID: ${meta.sessionId}`,
    `Effective state session ID: ${meta.effectiveSid}`,
    `State file: ${meta.stateFilePath}`,
    "",
    `Run the audit mode strategic review agent with this run-id (${runId}):`,
    `  Agent file: ${meta.auditAgentPath}`,
    "",
    `supervisor-audit を該当 run-id (${runId}) 付きで起動する。`,
    "この起動は /run-tests の dispatch と同一ターンで並行して発行してよい",
    "(review 結果を入力に必要としないため review_security 完了を待たない)。",
    "The agent records in_progress on start and writes its verdict against this run-id;",
    "if another trigger re-arms first, the compare-and-set discards the stale verdict.",
    "After it completes, continue the workflow — the next Stop event surfaces the result.",
  );
  return lines.join("\n");
}

// The whole Stop-hook Phase A step, folded into one call so the entrypoint stays a
// dispatcher (file-split Pattern A). Collects candidates from the workflow
// projection, coalesces/arms, and returns the S4-d block reason string when a run
// was armed, or null to fall through (no candidates, phase-guarded, or pure
// no-op consume). Fail-open: any internal throw yields null.
function evaluatePhaseA(sessionId, state, ctx) {
  // State being absent (fresh session) is not a reason to skip Phase A: TR1–TR5
  // edge triggers come from ctx.workflowProjection, not supervisor state. Removing
  // the !state short-circuit lets a first-time arm reach armAuditRun, which creates
  // the state file as a side effect. Phase checks below read from ctx (derived by
  // the caller from state), so they handle state=null correctly (#2256 C1).
  if (ctx && ctx.askUserQuestionTurn) return null;
  const auditPhase = (ctx && ctx.auditPhase) || null;
  if (auditPhase === "pending" || auditPhase === "in_progress" || auditPhase === "frozen") return null;
  if (ctx && ctx.alertPhase === "closed") return null;

  // Always drive the projection (array) form: candidatesFromProjection appends the
  // TR6 level candidate from state.alert.cumulative_severity, so a standing
  // cumSev=error arms even when no workflow projection object is present (S6-a).
  // Passing bare state would fall to the transcript (object) form and be dropped.
  // ctx.workflowProjection carries the workflow state current (readState from
  // workflow-state, loaded by supervisor-guard.js) — it is the canonical source
  // of TR1–TR5 step-completion edges. state is the supervisor state and has no
  // current.steps of its own; the fallback chain below keeps the function
  // invocable even when the workflow state is unavailable (fail-open, S6-a).
  const wfProj = (ctx && ctx.workflowProjection && typeof ctx.workflowProjection === "object" && ctx.workflowProjection.steps)
    ? ctx.workflowProjection
    : null;
  const projection = wfProj
    || ((state && state.current && typeof state.current === "object" && state.current.steps) ? state.current : null)
    || { steps: (state && state.steps) || {} };
  let candidates = [];
  try { candidates = collectAuditCandidates(projection, state) || []; } catch (_) { candidates = []; }
  if (!Array.isArray(candidates) || candidates.length === 0) return null;

  let plansDir;
  try { plansDir = getWorkflowPlansDir ? getWorkflowPlansDir() : undefined; } catch (_) { plansDir = undefined; }

  // Resolve the workflow session id for plan-artifact lookups: sessionId is the
  // CC uuid which does NOT match the timestamped artifact file prefix. Prefer env
  // var, then the shared resolver (WORKTREE_NOTES → CLAUDE_CODE_SESSION_ID guard →
  // context scan). Fall back to the CC uuid so freshness is computed conservatively
  // rather than crashing (session-id-resolution.md).
  let planSessionId = sessionId;
  try {
    let resolveWsid = null;
    try { ({ resolveWorkflowSessionId: resolveWsid } = require("../lib/resolve-workflow-session-id")); } catch (_) {}
    const envWsid = process.env.WORKFLOW_SESSION_ID;
    if (envWsid && /^[A-Za-z0-9_-]+$/.test(envWsid)) {
      planSessionId = envWsid;
    } else if (resolveWsid) {
      const wsid = resolveWsid({});
      if (wsid) planSessionId = wsid;
    }
  } catch (_) {}

  let armInfo = { action: "none" };
  try {
    armInfo = armFromCandidates(sessionId, candidates, {
      state,
      cwd: (ctx && ctx.cwd) || process.cwd(),
      plansDir,
      planSessionId,
    });
  } catch (_) { armInfo = { action: "none" }; }

  if (!armInfo || armInfo.action !== "arm") return null;
  return formatAuditArmReason(armInfo, (ctx && ctx.meta) || {});
}

module.exports = { armFromCandidates, formatAuditArmReason, coalesce, buildJudgmentSet, evaluatePhaseA };
