"use strict";
// Step table (#2527): the SSOT for the step order, which steps each deliverable
// type requires, the delivery paths that drop a step, and each step's commit-gate
// attribute. VALID_STEPS (state-io/core.js) is derived from stepNames(), so a new
// row here is a new step everywhere. Dependency-free on purpose: state-io loads it.

const REQ = "required";
const SKIP = "skip";

// [step, { "wf-code", "wf-meta" }, skipOnPaths, commitGate]
const ROWS = Object.freeze([
  ["workflow_init", { "wf-code": REQ, "wf-meta": REQ }, [], "required"],
  ["clarify_intent", { "wf-code": REQ, "wf-meta": REQ }, [], "required"],
  ["research", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt"],
  ["outline", { "wf-code": REQ, "wf-meta": REQ }, [], "required"],
  ["detail", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["branching_complete", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["write_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["review_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["write_code", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["run_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["review_security", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["docs", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["review_docs", { "wf-code": REQ, "wf-meta": SKIP }, [], "required"],
  ["push_branch", { "wf-code": REQ, "wf-meta": SKIP }, ["direct"], "exempt"],
  ["user_verification", { "wf-code": REQ, "wf-meta": SKIP }, [], "deferred-in-worktree"],
  ["merge_to_main", { "wf-code": REQ, "wf-meta": SKIP }, [], "exempt"],
  ["cleanup", { "wf-code": REQ, "wf-meta": SKIP }, ["direct"], "deferred-in-worktree"],
  ["pre_final_report_gate", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt"],
  ["final_report", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt"],
].map(([step, columns, skipOnPaths, commitGate]) => Object.freeze({
  step, columns: Object.freeze(columns), skipOnPaths: Object.freeze(skipOnPaths), commitGate,
})));

const BY_STEP = new Map(ROWS.map((r) => [r.step, r]));
const DELIVERABLE_TYPES = Object.freeze(["wf-code", "wf-meta"]);
const DEFAULT_DELIVERABLE_TYPE = "wf-code";

function stepNames() {
  return ROWS.map((r) => r.step);
}

// An unknown deliverable type reads as the default column: a table lookup must
// never make a step disappear because a value was misspelled.
function isStepRequired(profile, step) {
  const row = BY_STEP.get(step);
  if (!row) return false;
  const p = profile || {};
  const type = DELIVERABLE_TYPES.includes(p.deliverableType) ? p.deliverableType : DEFAULT_DELIVERABLE_TYPE;
  if (row.columns[type] !== REQ) return false;
  return !row.skipOnPaths.includes(p.deliveryPath);
}

function commitGateOf(step) {
  const row = BY_STEP.get(step);
  return row ? row.commitGate : null;
}

// Events written before a step rename keep the old name; readers fold them onto the current one.
const LEGACY_STEP_NAMES = Object.freeze({ deliver: "merge_to_main" });

function canonicalStepName(name) {
  return Object.prototype.hasOwnProperty.call(LEGACY_STEP_NAMES, name) ? LEGACY_STEP_NAMES[name] : name;
}

module.exports = {
  stepNames, isStepRequired, commitGateOf, canonicalStepName, DELIVERABLE_TYPES, DEFAULT_DELIVERABLE_TYPE,
};
