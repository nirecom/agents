"use strict";

const SCHEMA_VERSION = 1;

const CATEGORIES = [
  "intent", "outline", "detail",
  "workflow", "code", "test", "security",
  "performance", "env", "other",
];

const SEVERITY_VALUES = ["error", "warning", "notice"];

const L2_PHASE_VALUES = [null, "pending", "done", "frozen"];

const SEVERITY_RANK = { error: 2, warning: 1, notice: 0 };

// 2 = guarded fail-fast. One retry permits a transient API error to self-heal; the second consecutive failure freezes the session so the loop cannot continue.
const L2_RETRY_THRESHOLD = 2;

function createEmptyState(sessionId) {
  const now = new Date().toISOString();
  return {
    version: SCHEMA_VERSION,
    session_id: sessionId,
    created_at: now,
    last_updated: now,
    layer1: { findings: [] },
    layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0 },
    layer3: {},
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
  if (typeof obj.layer2 !== "object" || obj.layer2 === null || Array.isArray(obj.layer2)) {
    errors.push("layer2 must be an object");
  } else {
    const l2 = obj.layer2;
    if ("l2_armed_at" in l2 && l2.l2_armed_at !== null && typeof l2.l2_armed_at !== "string") {
      errors.push("layer2.l2_armed_at must be null or a string");
    }
    if ("last_run_at" in l2 && l2.last_run_at !== null && typeof l2.last_run_at !== "string") {
      errors.push("layer2.last_run_at must be null or a string");
    }
    if ("cumulative_severity" in l2 && l2.cumulative_severity !== null && !SEVERITY_VALUES.includes(l2.cumulative_severity)) {
      errors.push(`layer2.cumulative_severity must be null or one of ${SEVERITY_VALUES.join("|")}`);
    }
    if ("findings" in l2) {
      if (!Array.isArray(l2.findings)) {
        errors.push("layer2.findings must be an array");
      } else {
        for (let i = 0; i < l2.findings.length; i++) {
          const r = validateFinding(l2.findings[i]);
          if (!r.ok) {
            for (const e of r.errors) errors.push(`layer2.findings[${i}]: ${e}`);
          }
        }
      }
    }
    if ("l2_phase" in l2 && !L2_PHASE_VALUES.includes(l2.l2_phase)) errors.push("layer2.l2_phase must be null, pending, done, or frozen");
    if ("l2_cause" in l2 && l2.l2_cause !== null && typeof l2.l2_cause !== "string") errors.push("layer2.l2_cause must be null or a string");
    if ("l2_retry_count" in l2 && (!Number.isInteger(l2.l2_retry_count) || l2.l2_retry_count < 0)) errors.push("layer2.l2_retry_count must be a non-negative integer");
  }
  if (typeof obj.layer3 !== "object" || obj.layer3 === null || Array.isArray(obj.layer3)) {
    errors.push("layer3 must be an object");
  }
  return { ok: errors.length === 0, errors };
}

module.exports = {
  SCHEMA_VERSION,
  CATEGORIES,
  SEVERITY_VALUES,
  L2_PHASE_VALUES,
  SEVERITY_RANK,
  L2_RETRY_THRESHOLD,
  createEmptyState,
  validate,
  validateFinding,
};
