"use strict";

const SCHEMA_VERSION = 1;

const LAYER1_CHECKS = ["plan_artifact", "scope_keyword", "non_goal_keyword", "sentinel"];

const STATUS_VALUES = ["pass", "warn", "fail"];

const SEVERITY_RANK = { pass: 0, warn: 1, fail: 2 };

function createEmptyState(sessionId) {
  const now = new Date().toISOString();
  return {
    version: SCHEMA_VERSION,
    session_id: sessionId,
    created_at: now,
    last_updated: now,
    layer1: { findings: [] },
    layer2: {},
    layer3: {},
  };
}

function validateFinding(f) {
  const errors = [];
  if (!f || typeof f !== "object") return { ok: false, errors: ["finding must be an object"] };
  if (!LAYER1_CHECKS.includes(f.check)) errors.push(`invalid check: ${f.check}`);
  if (!STATUS_VALUES.includes(f.status)) errors.push(`invalid status: ${f.status}`);
  if (typeof f.detail !== "string") errors.push("detail must be a string");
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
  }
  if (typeof obj.layer3 !== "object" || obj.layer3 === null || Array.isArray(obj.layer3)) {
    errors.push("layer3 must be an object");
  }
  return { ok: errors.length === 0, errors };
}

module.exports = {
  SCHEMA_VERSION,
  LAYER1_CHECKS,
  STATUS_VALUES,
  SEVERITY_RANK,
  createEmptyState,
  validate,
  validateFinding,
};
