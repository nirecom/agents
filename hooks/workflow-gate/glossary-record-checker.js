"use strict";
// Commit-gate glossary_check re-judge (#2529 T6-5): review_tests / review_security /
// review_docs records are evaluated against the CURRENT staged set (rule R-S, per-commit).

const { evaluateGlossaryCheck } = require("../workflow-state/glossary-check/record");

const GATED_STEPS = Object.freeze(["review_tests", "review_security", "review_docs"]);

// checkGlossaryRecord(step, { state, sessionId, repoDir }) -> { action: "pass" } | { action: "block", reason }
// The reason carries the shared recovery text of record.js (CPR-SSOT, #2909).
function checkGlossaryRecord(step, ctx) {
  if (!GATED_STEPS.includes(step)) return { action: "pass" };
  const c = ctx || {};
  const v = evaluateGlossaryCheck(c.sessionId, step, c.state, { repoDir: c.repoDir, mode: "commit" });
  if (v.ok) return { action: "pass" };
  return { action: "block", reason: `${step}: ${v.code} — ${v.detail.recovery}` };
}

module.exports = { checkGlossaryRecord, GATED_STEPS };
