"use strict";

const SCHEMA_VERSION = 1;

const CATEGORIES = [
  "intent", "outline", "detail",
  "workflow", "code", "test", "security",
  "performance", "env", "other",
];

const SEVERITY_VALUES = ["error", "warning", "notice"];

const SEVERITY_RANK = { error: 2, warning: 1, notice: 0 };

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
  CATEGORIES,
  SEVERITY_VALUES,
  SEVERITY_RANK,
  createEmptyState,
  validate,
  validateFinding,
};
