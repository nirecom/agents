"use strict";
// Commit-gate glossary_check re-judge (#2529 T6-5): review_tests / review_security /
// review_docs records are evaluated against the CURRENT staged set (rule R-S, per-commit).

const { evaluateGlossaryCheck } = require("../workflow-state/glossary-check/record");
const { stageOfStep } = require("../workflow-state/glossary-check/scope");

const GATED_STEPS = Object.freeze(["review_tests", "review_security", "review_docs"]);

function detailText(v) {
  const d = v.detail || {};
  if (v.code === "glossary-check-stale" && Array.isArray(d.changed) && d.changed.length > 0) {
    return ` (changed: ${d.changed.join(", ")})`;
  }
  if (v.code === "glossary-findings-unresolved" && Array.isArray(d.findings)) {
    return ` (${d.findings.length} unresolved finding(s))`;
  }
  if (v.code === "glossary-fingerprint-unavailable" && d.error) return ` (${d.error})`;
  return "";
}

// checkGlossaryRecord(step, { state, sessionId, repoDir }) -> { action: "pass" } | { action: "block", reason }
function checkGlossaryRecord(step, ctx) {
  if (!GATED_STEPS.includes(step)) return { action: "pass" };
  const c = ctx || {};
  const v = evaluateGlossaryCheck(c.sessionId, step, c.state, { repoDir: c.repoDir, mode: "commit" });
  if (v.ok) return { action: "pass" };
  const stage = stageOfStep(step);
  return {
    action: "block",
    reason: `${step}: ${v.code}${detailText(v)} — run: check-glossary-drift --stage ${stage} --record ` +
      `(session ${c.sessionId || "<sid>"}), then fix each DRIFT finding or record an ACCEPTED grant.`,
  };
}

module.exports = { checkGlossaryRecord, GATED_STEPS };
