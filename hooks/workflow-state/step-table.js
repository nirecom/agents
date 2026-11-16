"use strict";
// Step table (#2527): the SSOT for the step order, which steps each deliverable
// type requires, the delivery paths that drop a step, and each step's commit-gate
// attribute. VALID_STEPS (state-io/core.js) is derived from stepNames(), so a new
// row here is a new step everywhere. Dependency-free on purpose: state-io loads it.

const REQ = "required";
const SKIP = "skip";

const PRE = "pre-implementation";
const IMPL = "implementation";

// [step, { "wf-code", "wf-meta" }, skipOnPaths, commitGate, phase]
// phase (#2852): the reset allowance refills on an approved reset to a pre-implementation step only.
const ROWS = Object.freeze([
  ["workflow_init", { "wf-code": REQ, "wf-meta": REQ }, [], "required", PRE],
  ["clarify_intent", { "wf-code": REQ, "wf-meta": REQ }, [], "required", PRE],
  ["research", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt", PRE],
  ["outline", { "wf-code": REQ, "wf-meta": REQ }, [], "required", PRE],
  ["detail", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", PRE],
  ["branching_complete", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["write_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["review_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["write_code", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["run_tests", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["review_security", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["docs", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["review_docs", { "wf-code": REQ, "wf-meta": SKIP }, [], "required", IMPL],
  ["push_branch", { "wf-code": REQ, "wf-meta": SKIP }, ["direct"], "exempt", IMPL],
  ["user_verification", { "wf-code": REQ, "wf-meta": SKIP }, [], "deferred-in-worktree", IMPL],
  ["merge_to_main", { "wf-code": REQ, "wf-meta": SKIP }, [], "exempt", IMPL],
  ["cleanup", { "wf-code": REQ, "wf-meta": SKIP }, ["direct"], "deferred-in-worktree", IMPL],
  ["pre_final_report_gate", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt", IMPL],
  ["final_report", { "wf-code": REQ, "wf-meta": REQ }, [], "exempt", IMPL],
].map(([step, columns, skipOnPaths, commitGate, phase]) => Object.freeze({
  step, columns: Object.freeze(columns), skipOnPaths: Object.freeze(skipOnPaths), commitGate, phase: phase || null,
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

// phaseOf(step) -> "pre-implementation" | "implementation"; null for an unknown step or a row without the column.
function phaseOf(step) {
  const row = typeof step === "string" ? BY_STEP.get(step) : undefined;
  return row ? row.phase : null;
}

// Events written before a step rename keep the old name; readers fold them onto the current one.
const LEGACY_STEP_NAMES = Object.freeze({ deliver: "merge_to_main" });

function canonicalStepName(name) {
  return Object.prototype.hasOwnProperty.call(LEGACY_STEP_NAMES, name) ? LEGACY_STEP_NAMES[name] : name;
}

module.exports = {
  stepNames, isStepRequired, commitGateOf, phaseOf, canonicalStepName, DELIVERABLE_TYPES, DEFAULT_DELIVERABLE_TYPE,
};
