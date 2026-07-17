"use strict";

const fs = require("fs");
const { validateFinding, validate, SEVERITY_VALUES, ALERT_PHASE_VALUES, ALERT_ELIGIBLE_PHASE_VALUES, ALERT_RETRY_THRESHOLD } = require("../supervisor-state-schema");
const findingStatus = require("../supervisor-finding-status");
const {
  ALERT_PATCH_KEYS,
  getStatePath,
  readStateOrInit,
  writeAtomic,
  validateAlertPhaseTransition,
} = require("./shared");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");

function writeAlertState(sessionId, patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return false;

  // Reject unknown keys
  for (const k of Object.keys(patch)) {
    if (!ALERT_PATCH_KEYS.has(k)) return false;
  }

  // Validate scalar override types
  if ("alert_armed_at" in patch && patch.alert_armed_at !== null && typeof patch.alert_armed_at !== "string") return false;
  if ("last_run_at" in patch && patch.last_run_at !== null && typeof patch.last_run_at !== "string") return false;
  if ("cumulative_severity" in patch && patch.cumulative_severity !== null && !SEVERITY_VALUES.includes(patch.cumulative_severity)) return false;
  if ("alert_phase" in patch && !ALERT_PHASE_VALUES.includes(patch.alert_phase)) return false;
  if ("alert_cause" in patch && patch.alert_cause !== null && typeof patch.alert_cause !== "string") return false;
  if ("findings_surfaced_at" in patch && patch.findings_surfaced_at !== null && typeof patch.findings_surfaced_at !== "string") return false;
  if ("alert_eligible_phase" in patch && !ALERT_ELIGIBLE_PHASE_VALUES.includes(patch.alert_eligible_phase)) return false;

  // Validate findings
  if ("findings" in patch) {
    if (!Array.isArray(patch.findings)) return false;
    for (const f of patch.findings) {
      const vr = validateFinding(f);
      if (!vr.ok) return false;
    }
  }

  const plansDir = getWorkflowPlansDir();
  fs.mkdirSync(plansDir, { recursive: true });
  const filePath = getStatePath(sessionId);

  const state = readStateOrInit(sessionId);

  // Up-cast S-1-era alert to S-2 shape
  const existing = state.alert && typeof state.alert === "object" && !Array.isArray(state.alert) ? state.alert : {};
  const currentPhase = (existing.alert_phase === undefined) ? null : existing.alert_phase;
  if ("alert_phase" in patch) {
    const vr = validateAlertPhaseTransition(currentPhase, patch.alert_phase);
    if (!vr.ok) {
      console.error("[supervisor-state-writer] invalid alert_phase transition: " + vr.errors.join("; "));
      return false;
    }
  }
  const effectivePhase = ("alert_phase" in patch) ? patch.alert_phase : currentPhase;
  if ((effectivePhase === "done" || effectivePhase === "paused" || effectivePhase === "closed") && "alert_armed_at" in patch && patch.alert_armed_at !== null) {
    console.error("[supervisor-state-writer] cannot set alert_armed_at while alert_phase=" + effectivePhase);
    return false;
  }
  const alert = {
    alert_armed_at: null,
    last_run_at: null,
    cumulative_severity: null,
    findings: [],
    alert_phase: null,
    alert_cause: null,
    alert_retry_count: 0,
    findings_surfaced_at: null,
    alert_eligible_phase: null,
    ...existing,
  };

  // Apply scalar overrides (explicit-clear via null permitted)
  if ("alert_armed_at" in patch) alert.alert_armed_at = patch.alert_armed_at;
  if ("last_run_at" in patch) alert.last_run_at = patch.last_run_at;
  if ("cumulative_severity" in patch) alert.cumulative_severity = patch.cumulative_severity;
  if ("alert_phase" in patch) alert.alert_phase = patch.alert_phase;
  if ("alert_cause" in patch) alert.alert_cause = patch.alert_cause;

  // Co-clear alert_cause when alert_armed_at is cleared to prevent stale-cause mislabeling
  if ("alert_armed_at" in patch && patch.alert_armed_at === null && !("alert_cause" in patch)) {
    alert.alert_cause = null;
  }
  if ("alert_retry_count" in patch) alert.alert_retry_count = patch.alert_retry_count;
  if ("findings_surfaced_at" in patch) alert.findings_surfaced_at = patch.findings_surfaced_at;
  if ("alert_eligible_phase" in patch) alert.alert_eligible_phase = patch.alert_eligible_phase;

  // #905: terminal states must never carry a stale alert_armed_at.
  if (effectivePhase === "done" || effectivePhase === "paused" || effectivePhase === "closed") {
    alert.alert_armed_at = null;
    alert.alert_cause = null;
    if (effectivePhase === "closed") alert.alert_eligible_phase = null;
  }

  // #912 C-HIGH-3: supervisor success path resets retry counter at writer SSOT.
  // Applies to ANY writeAlertState caller setting alert_phase=done (not just CLI),
  // so direct callers cannot leave a stale alert_retry_count carrying into the next cycle.
  // Explicit alert_retry_count in patch wins (test fixtures may set non-zero values).
  if (effectivePhase === "done" && !("alert_retry_count" in patch)) {
    alert.alert_retry_count = 0;
  }

  // Append findings. Draft-status entries get auto-assigned idx for later --confirm/--drop.
  if ("findings" in patch) {
    const ts = new Date().toISOString();
    for (const f of patch.findings) {
      const entry = { ...f, timestamp: ts };
      if (entry.status === "draft" && entry.idx === undefined) entry.idx = alert.findings.length;
      alert.findings.push(entry);
    }
  }

  state.alert = alert;
  state.last_updated = new Date().toISOString();

  const vr2 = validate(state);
  if (!vr2.ok) {
    console.error(`[supervisor-state-writer] writeAlertState validate failed: ${vr2.errors.join("; ")}`);
    return false;
  }

  writeAtomic(filePath, state);
  return true;
}

function incrementAlertRetryCount(sessionId) {
  const state = readStateOrInit(sessionId);
  const al = state.alert || {};
  // #912 C-HIGH-2: paused, done, and closed are all terminal for retry — never increment from any.
  // Without the done short-circuit, a stale retry_count on a done session could be
  // incremented into paused via a later C3 / cumSev=error path, corrupting terminal-state semantics.
  if (al.alert_phase === "paused" || al.alert_phase === "done" || al.alert_phase === "closed") {
    return { count: al.alert_retry_count || 0, frozen: al.alert_phase === "paused" };
  }
  const nextCount = (al.alert_retry_count || 0) + 1;
  if (nextCount >= ALERT_RETRY_THRESHOLD) {
    writeAlertState(sessionId, { alert_retry_count: nextCount, alert_phase: "paused" });
    return { count: nextCount, frozen: true };
  }
  writeAlertState(sessionId, { alert_retry_count: nextCount });
  return { count: nextCount, frozen: false };
}

function mutateAlertState(sid, mutator) {
  const fp = getStatePath(sid); const state = readStateOrInit(sid); mutator(state);
  state.last_updated = new Date().toISOString();
  const vr = validate(state);
  if (!vr.ok) { console.error(`[supervisor-state-writer] mutate failed: ${vr.errors.join("; ")}`); return false; }
  writeAtomic(fp, state); return true;
}

const confirmFinding = (sid, idx) => mutateAlertState(sid, (s) => findingStatus.confirmFinding(s, idx));
const dropFindings = (sid, idxs) => mutateAlertState(sid, (s) => findingStatus.dropFindings(s, idxs));
const promotePendingDraftsToConfirmed = (sid) => mutateAlertState(sid, (s) => findingStatus.promotePendingDraftsToConfirmed(s));

module.exports = {
  writeAlertState,
  incrementAlertRetryCount,
  confirmFinding,
  dropFindings,
  promotePendingDraftsToConfirmed,
};
