"use strict";

const SCHEMA_VERSION = 1;

const CATEGORIES = [
  "intent", "outline", "detail",
  "workflow", "code", "test", "security",
  "performance", "env", "other",
];

const SEVERITY_VALUES = ["error", "warning", "notice"];

const ALERT_PHASE_VALUES = [null, "pending", "done", "frozen"];

const ALERT_ELIGIBLE_PHASE_VALUES = [null, "post_final_report_window"];

const SEVERITY_RANK = { error: 2, warning: 1, notice: 0 };

// 2 = guarded fail-fast. One retry permits a transient API error to self-heal; the second consecutive failure freezes the session so the loop cannot continue.
const ALERT_RETRY_THRESHOLD = 2;

// Audit (#720) — audit mode strategic review.
const AUDIT_PHASE_VALUES = [null, "pending", "in_progress", "done", "frozen"];
const AUDIT_VERDICT_VALUES = ["CONTINUE", "WARN", "BLOCK"];
const AUDIT_RETRY_THRESHOLD = 2;
// Cumulative severity threshold (using SEVERITY_RANK comparison) that triggers audit arming.
const AUDIT_SEVERITY_THRESHOLD = "error";

function createEmptyState(sessionId) {
  const now = new Date().toISOString();
  return {
    version: SCHEMA_VERSION,
    session_id: sessionId,
    created_at: now,
    last_updated: now,
    layer1: { findings: [] },
    alert: { alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: null, alert_cause: null, alert_retry_count: 0, findings_surfaced_at: null, alert_eligible_phase: null },
    audit: { audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] },
  };
}

function validateFinding(f) {
  const errors = [];
  if (!f || typeof f !== "object") return { ok: false, errors: ["finding must be an object"] };
  if (!Array.isArray(f.categories) || f.categories.length === 0) {
    errors.push("categories must be a non-empty array");
  } else {
    for (const c of f.categories) {
      if (!CATEGORIES.includes(c)) errors.push(`invalid category: ${c}`);
    }
  }
  if (!SEVERITY_VALUES.includes(f.severity)) errors.push(`invalid severity: ${f.severity}`);
  if (typeof f.detail !== "string") errors.push("detail must be a string");
  if (f.reporter !== undefined && typeof f.reporter !== "string") {
    errors.push("reporter must be a string");
  }
  // Axis A (#885): optional fields — reason, context, co_blocked_by.
  if (f.reason !== undefined) {
    if (typeof f.reason !== "string" || f.reason.length < 1) {
      errors.push("reason must be a non-empty string");
    }
  }
  if (f.context !== undefined) {
    if (!f.context || typeof f.context !== "object" || Array.isArray(f.context)) {
      errors.push("context must be a non-null object");
    } else {
      if (f.context.cwd !== undefined && typeof f.context.cwd !== "string") {
        errors.push("context.cwd must be a string");
      }
      if (f.context.git_root_resolved !== undefined && typeof f.context.git_root_resolved !== "boolean") {
        errors.push("context.git_root_resolved must be a boolean");
      }
    }
  }
  if (f.co_blocked_by !== undefined) {
    if (!Array.isArray(f.co_blocked_by)) {
      errors.push("co_blocked_by must be an array");
    } else {
      for (const r of f.co_blocked_by) {
        if (typeof r !== "string" || r.length < 1) {
          errors.push("co_blocked_by elements must be non-empty strings");
          break;
        }
      }
    }
  }
  if (f.status !== undefined && f.status !== "draft" && f.status !== "confirmed") {
    errors.push(`invalid status: ${f.status} (must be draft or confirmed)`);
  }
  if (f.idx !== undefined && !Number.isInteger(f.idx)) {
    errors.push("idx must be an integer");
  }
  return { ok: errors.length === 0, errors };
}

function validate(obj) {
  const errors = [];
  if (!obj || typeof obj !== "object") return { ok: false, errors: ["state must be an object"] };
  if (typeof obj.version !== "number") errors.push("version must be a number");
  if (typeof obj.session_id !== "string" || !obj.session_id) errors.push("session_id required");
  if (typeof obj.created_at !== "string") errors.push("created_at required");
  if (typeof obj.last_updated !== "string") errors.push("last_updated required");
  if (!obj.layer1 || typeof obj.layer1 !== "object") {
    errors.push("layer1 required");
  } else if (!Array.isArray(obj.layer1.findings)) {
    errors.push("layer1.findings must be an array");
  } else {
    for (let i = 0; i < obj.layer1.findings.length; i++) {
      const r = validateFinding(obj.layer1.findings[i]);
      if (!r.ok) {
        for (const e of r.errors) errors.push(`findings[${i}]: ${e}`);
      }
    }
  }
  if (typeof obj.alert !== "object" || obj.alert === null || Array.isArray(obj.alert)) {
    errors.push("alert must be an object");
  } else {
    const al = obj.alert;
    if ("alert_armed_at" in al && al.alert_armed_at !== null && typeof al.alert_armed_at !== "string") {
      errors.push("alert.alert_armed_at must be null or a string");
    }
    if ("last_run_at" in al && al.last_run_at !== null && typeof al.last_run_at !== "string") {
      errors.push("alert.last_run_at must be null or a string");
    }
    if ("cumulative_severity" in al && al.cumulative_severity !== null && !SEVERITY_VALUES.includes(al.cumulative_severity)) {
      errors.push(`alert.cumulative_severity must be null or one of ${SEVERITY_VALUES.join("|")}`);
    }
    if ("findings" in al) {
      if (!Array.isArray(al.findings)) {
        errors.push("alert.findings must be an array");
      } else {
        for (let i = 0; i < al.findings.length; i++) {
          const r = validateFinding(al.findings[i]);
          if (!r.ok) {
            for (const e of r.errors) errors.push(`alert.findings[${i}]: ${e}`);
          }
        }
      }
    }
    if ("alert_phase" in al && !ALERT_PHASE_VALUES.includes(al.alert_phase)) errors.push("alert.alert_phase must be null, pending, done, or frozen");
    if ("alert_cause" in al && al.alert_cause !== null && typeof al.alert_cause !== "string") errors.push("alert.alert_cause must be null or a string");
    if ("alert_retry_count" in al && (!Number.isInteger(al.alert_retry_count) || al.alert_retry_count < 0)) errors.push("alert.alert_retry_count must be a non-negative integer");
    if ("findings_surfaced_at" in al && al.findings_surfaced_at !== null && typeof al.findings_surfaced_at !== "string") {
      errors.push("alert.findings_surfaced_at must be null or a string");
    }
    if ("alert_eligible_phase" in al && !ALERT_ELIGIBLE_PHASE_VALUES.includes(al.alert_eligible_phase)) {
      errors.push(`alert.alert_eligible_phase must be null or "post_final_report_window"`);
    }
  }
  if (typeof obj.audit !== "object" || obj.audit === null || Array.isArray(obj.audit)) {
    errors.push("audit must be an object");
  } else {
    const au = obj.audit;
    if ("audit_phase" in au && !AUDIT_PHASE_VALUES.includes(au.audit_phase)) errors.push("audit.audit_phase must be null, pending, in_progress, done, or frozen");
    if ("audit_verdict" in au && au.audit_verdict !== null && !AUDIT_VERDICT_VALUES.includes(au.audit_verdict)) errors.push("audit.audit_verdict must be null, CONTINUE, WARN, or BLOCK");
    if ("audit_last_run_at" in au && au.audit_last_run_at !== null && typeof au.audit_last_run_at !== "string") errors.push("audit.audit_last_run_at must be null or a string");
    if ("audit_armed_at" in au && au.audit_armed_at !== null && typeof au.audit_armed_at !== "string") errors.push("audit.audit_armed_at must be null or a string");
    if ("audit_cause" in au && au.audit_cause !== null && typeof au.audit_cause !== "string") errors.push("audit.audit_cause must be null or a string");
    if ("audit_retry_count" in au && (!Number.isInteger(au.audit_retry_count) || au.audit_retry_count < 0)) errors.push("audit.audit_retry_count must be a non-negative integer");
    if ("findings" in au && !Array.isArray(au.findings)) errors.push("audit.findings must be an array");
  }
  return { ok: errors.length === 0, errors };
}

module.exports = {
  SCHEMA_VERSION,
  CATEGORIES,
  SEVERITY_VALUES,
  ALERT_PHASE_VALUES,
  ALERT_ELIGIBLE_PHASE_VALUES,
  SEVERITY_RANK,
  ALERT_RETRY_THRESHOLD,
  AUDIT_PHASE_VALUES,
  AUDIT_VERDICT_VALUES,
  AUDIT_RETRY_THRESHOLD,
  AUDIT_SEVERITY_THRESHOLD,
  createEmptyState,
  validate,
  validateFinding,
};
