"use strict";

const fs = require("fs");
const { withStateLock } = require("./lock");
const { validateFinding, validate, AUDIT_PHASE_VALUES, AUDIT_VERDICT_VALUES, AUDIT_RETRY_THRESHOLD } = require("../supervisor-state-schema");
const {
  SESSION_ID_RE,
  getStatePath,
  readStateOrInit,
  writeAtomic,
} = require("./shared");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { capDeclaredFiles } = require("../audit-ledger");
const { armAuditRun, finalizeAuditRun, recordBlockOverride } = require("./audit-run");

// #720: Audit writer. Symmetric to writeAlertState — accepts a small patch
// object, validates each field's type/enum, then merges into state.audit.
// #2256 S2-a extends the patch surface with the run-identity fields.
const AUDIT_PATCH_KEYS = new Set([
  "audit_phase", "audit_verdict", "audit_last_run_at", "audit_armed_at", "audit_cause",
  "audit_retry_count", "findings",
  "audit_verdict_summary", "audit_dispatched_at", "audit_run_id", "run_seq",
  "last_terminal_run_id", "declared_files", "uv_attempt_seq",
]);

function writeAuditStateCore(sessionId, patch) {
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
  if ("audit_verdict_summary" in patch && patch.audit_verdict_summary !== null && typeof patch.audit_verdict_summary !== "string") return false;
  if ("audit_dispatched_at" in patch && patch.audit_dispatched_at !== null && typeof patch.audit_dispatched_at !== "string") return false;
  if ("audit_run_id" in patch && patch.audit_run_id !== null && typeof patch.audit_run_id !== "string") return false;
  if ("last_terminal_run_id" in patch && patch.last_terminal_run_id !== null && typeof patch.last_terminal_run_id !== "string") return false;
  if ("run_seq" in patch && (!Number.isInteger(patch.run_seq) || patch.run_seq < 0)) return false;
  if ("uv_attempt_seq" in patch && (!Number.isInteger(patch.uv_attempt_seq) || patch.uv_attempt_seq < 0)) return false;
  if ("declared_files" in patch && patch.declared_files !== null &&
      (typeof patch.declared_files !== "object" || Array.isArray(patch.declared_files))) return false;
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
    } else if (k === "declared_files") {
      state.audit.declared_files = v === null ? null : capDeclaredFiles(v);
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

// Locked wrapper: the lock is held across the read-modify-write, never only
// around the final writeAtomic.
function writeAuditState(sessionId, patch) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  return withStateLock(getStatePath(sessionId), () => writeAuditStateCore(sessionId, patch)) === true;
}

// CAS clear: applies patch only when the current audit_phase matches expectedPhase.
// Prevents Phase B from clearing a newly armed "pending" run that raced in after
// the pre-lock "done" snapshot was read (#2256 stale-clear race).
function writeAuditStateCas(sessionId, expectedPhase, patch) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return false;
  return withStateLock(getStatePath(sessionId), () => {
    const fresh = readStateOrInit(sessionId);
    const currentPhase = (fresh.audit && fresh.audit.audit_phase != null)
      ? fresh.audit.audit_phase : null;
    if (currentPhase !== expectedPhase) return false;
    return writeAuditStateCore(sessionId, patch);
  }) === true;
}

function incrementAuditRetryCountCore(sessionId) {
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

function incrementAuditRetryCount(sessionId) {
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) return { count: 0, frozen: false };
  const r = withStateLock(getStatePath(sessionId), () => incrementAuditRetryCountCore(sessionId));
  return r === undefined ? { count: 0, frozen: false } : r;
}

module.exports = {
  AUDIT_PATCH_KEYS,
  writeAuditState,
  writeAuditStateCas,
  incrementAuditRetryCount,
  armAuditRun,
  finalizeAuditRun,
  recordBlockOverride,
};
