"use strict";

const fs = require("fs");
const { validateFinding, validate, AUDIT_PHASE_VALUES, AUDIT_VERDICT_VALUES, AUDIT_RETRY_THRESHOLD } = require("../supervisor-state-schema");
const {
  SESSION_ID_RE,
  getStatePath,
  readStateOrInit,
  writeAtomic,
} = require("./shared");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");

// #720: Audit writer. Symmetric to writeAlertState — accepts a small patch
// object, validates each field's type/enum, then merges into state.audit.
const AUDIT_PATCH_KEYS = new Set(["audit_phase", "audit_verdict", "audit_last_run_at", "audit_armed_at", "audit_cause", "audit_retry_count", "findings"]);

function writeAuditState(sessionId, patch) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return false;

  for (const k of Object.keys(patch)) {
    if (!AUDIT_PATCH_KEYS.has(k)) return false;
  }

  if ("audit_phase" in patch && !AUDIT_PHASE_VALUES.includes(patch.audit_phase)) return false;
  if ("audit_verdict" in patch && patch.audit_verdict !== null && !AUDIT_VERDICT_VALUES.includes(patch.audit_verdict)) return false;
  if ("audit_last_run_at" in patch && patch.audit_last_run_at !== null && typeof patch.audit_last_run_at !== "string") return false;
  if ("audit_armed_at" in patch && patch.audit_armed_at !== null && typeof patch.audit_armed_at !== "string") return false;
  if ("audit_cause" in patch && patch.audit_cause !== null && typeof patch.audit_cause !== "string") return false;
  if ("audit_retry_count" in patch && (!Number.isInteger(patch.audit_retry_count) || patch.audit_retry_count < 0)) return false;
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
  if (!state.audit || typeof state.audit !== "object" || Array.isArray(state.audit)) {
    state.audit = {};
  }

  for (const [k, v] of Object.entries(patch)) {
    if (k === "findings") {
      if (!Array.isArray(state.audit.findings)) state.audit.findings = [];
      const ts = new Date().toISOString();
      for (const f of v) state.audit.findings.push({ ...f, timestamp: ts });
    } else {
      state.audit[k] = v;
    }
  }
  // #912 mirror C-HIGH-3 to audit: setting phase=done resets retry counter at SSOT.
  if (patch.audit_phase === "done" && !("audit_retry_count" in patch)) {
    state.audit.audit_retry_count = 0;
  }
  state.last_updated = new Date().toISOString();

  const vr = validate(state);
  if (!vr.ok) {
    console.error(`[supervisor-state-writer] writeAuditState validate failed: ${vr.errors.join("; ")}`);
    return false;
  }
  writeAtomic(filePath, state);
  return true;
}

function incrementAuditRetryCount(sessionId) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { count: 0, frozen: false };
  const state = readStateOrInit(sessionId);
  if (!state.audit || typeof state.audit !== "object" || Array.isArray(state.audit)) {
    state.audit = {};
  }
  const au = state.audit;
  // Terminal-state short-circuit (symmetric to alert increment).
  if (au.audit_phase === "frozen" || au.audit_phase === "done") {
    return { count: au.audit_retry_count || 0, frozen: au.audit_phase === "frozen" };
  }
  const nextCount = (au.audit_retry_count || 0) + 1;
  const patch = { audit_retry_count: nextCount };
  if (nextCount >= AUDIT_RETRY_THRESHOLD) patch.audit_phase = "frozen";
  writeAuditState(sessionId, patch);
  return { count: nextCount, frozen: nextCount >= AUDIT_RETRY_THRESHOLD };
}

module.exports = { writeAuditState, incrementAuditRetryCount };
