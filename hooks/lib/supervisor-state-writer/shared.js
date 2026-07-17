"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");

const ALERT_PATCH_KEYS = new Set(["alert_armed_at", "last_run_at", "cumulative_severity", "findings", "alert_phase", "alert_cause", "alert_retry_count", "findings_surfaced_at", "alert_eligible_phase"]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

// Axis A (#885) — co-block back-annotation tuning.
// Scan only the most recent N findings, only when within W ms of the new
// finding's timestamp. Both bounds protect against cross-event correlation
// (idle session reuses, or unrelated bursts).
const CO_BLOCK_RECENCY = 5;
const CO_BLOCK_WINDOW_MS = 10000;

// Sibling-match key extraction (#885).
// Hooks self-report via reportBlock() with detail of shape
// `hook blocked: <reporter> on <command>`. To correlate a new block with a
// recent sibling block of the SAME command but DIFFERENT reporter, strip the
// "hook blocked: <reporter> on " prefix so the residual is just the command.
// Falls back to the full detail when the prefix is absent (non-block finding).
function extractCoBlockKey(detail) {
  if (typeof detail !== "string") return null;
  const m = detail.match(/^hook blocked: [^ ]+ on (.*)$/);
  return m ? m[1] : detail;
}

function unionStableDedup(existing, additions) {
  const seen = new Set();
  const out = [];
  if (Array.isArray(existing)) {
    for (const r of existing) {
      if (typeof r === "string" && !seen.has(r)) { seen.add(r); out.push(r); }
    }
  }
  for (const r of additions) {
    if (typeof r === "string" && !seen.has(r)) { seen.add(r); out.push(r); }
  }
  return out;
}

function getStatePath(sessionId) {
  if (!SESSION_ID_RE.test(sessionId)) throw new Error(`invalid sessionId: ${sessionId}`);
  return path.join(getWorkflowPlansDir(), `${sessionId}-supervisor-state.json`);
}

// Migrate pre-#1092 layer2/layer3 schema to alert/audit in-place.
// Called by readStateOrInit; safe to call on already-migrated states.
function migrateLegacyState(state) {
  if (state.layer2 && typeof state.layer2 === "object" && !Array.isArray(state.layer2) &&
      (typeof state.alert !== "object" || state.alert === null || Array.isArray(state.alert))) {
    const l2 = state.layer2;
    state.alert = {
      alert_armed_at: l2.l2_armed_at !== undefined ? l2.l2_armed_at : null,
      last_run_at: l2.last_run_at !== undefined ? l2.last_run_at : null,
      cumulative_severity: l2.cumulative_severity !== undefined ? l2.cumulative_severity : null,
      findings: Array.isArray(l2.findings) ? l2.findings : [],
      alert_phase: l2.l2_phase !== undefined ? l2.l2_phase : null,
      alert_cause: l2.l2_cause !== undefined ? l2.l2_cause : null,
      alert_retry_count: typeof l2.l2_retry_count === "number" ? l2.l2_retry_count : 0,
      findings_surfaced_at: l2.findings_surfaced_at !== undefined ? l2.findings_surfaced_at : null,
      alert_eligible_phase: l2.l2_eligible_phase !== undefined ? l2.l2_eligible_phase : null,
    };
    delete state.layer2;
  }
  if (state.layer3 && typeof state.layer3 === "object" && !Array.isArray(state.layer3) &&
      (typeof state.audit !== "object" || state.audit === null || Array.isArray(state.audit))) {
    const l3 = state.layer3;
    state.audit = {
      audit_phase: l3.l3_phase !== undefined ? l3.l3_phase : null,
      audit_verdict: l3.l3_verdict !== undefined ? l3.l3_verdict : null,
      audit_last_run_at: l3.l3_last_run_at !== undefined ? l3.l3_last_run_at : null,
      audit_armed_at: l3.l3_armed_at !== undefined ? l3.l3_armed_at : null,
      audit_cause: l3.l3_cause !== undefined ? l3.l3_cause : null,
      audit_retry_count: typeof l3.l3_retry_count === "number" ? l3.l3_retry_count : 0,
      findings: Array.isArray(l3.findings) ? l3.findings : [],
    };
    delete state.layer3;
  }
  // Backfill top-level timestamps required by validate() that pre-#1092 states lack.
  const now = new Date().toISOString();
  if (!state.created_at) state.created_at = now;
  if (!state.last_updated) state.last_updated = now;
  // --- BEGIN temporary: alert_phase "frozen" → "paused" migration (#1166) ---
  if (state.alert && typeof state.alert === "object" && !Array.isArray(state.alert) &&
      state.alert.alert_phase === "frozen") {
    state.alert.alert_phase = "paused";
  }
  // --- END temporary: alert_phase "frozen" → "paused" migration (#1166) ---
  return state;
}

function readStateOrInit(sessionId) {
  const { createEmptyState } = require("../supervisor-state-schema");
  const filePath = getStatePath(sessionId);
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    return migrateLegacyState(JSON.parse(raw));
  } catch (_) {
    return createEmptyState(sessionId);
  }
}

function writeAtomic(filePath, state) {
  const tmpPath = filePath + ".tmp";
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function validateAlertPhaseTransition(currentPhase, nextPhase) {
  if (currentPhase === nextPhase) return { ok: true, errors: [] };
  if (currentPhase === "closed") return { ok: false, errors: ["cannot transition from closed: closed is a permanent terminal state"] };
  if (currentPhase === "paused" && nextPhase !== "pending") return { ok: false, errors: ["cannot transition from paused: only paused→pending (re-arm) is allowed"] };
  if (currentPhase === "done" && nextPhase === "pending") return { ok: false, errors: ["cannot re-schedule alert after done"] };
  if (currentPhase === "done" && nextPhase === null) return { ok: false, errors: ["cannot revert done to null"] };
  return { ok: true, errors: [] };
}

module.exports = {
  ALERT_PATCH_KEYS,
  SESSION_ID_RE,
  CO_BLOCK_RECENCY,
  CO_BLOCK_WINDOW_MS,
  extractCoBlockKey,
  unionStableDedup,
  getStatePath,
  readStateOrInit,
  writeAtomic,
  validateAlertPhaseTransition,
};
