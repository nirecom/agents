#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/step-table.js, hooks/workflow-state/plan-step-table.js
// Tags: TL1, step-table, reset-allowance, phase, scope:issue-specific, pwsh-not-required
// #2852: every step table row carries a phase ("pre-implementation" / "implementation") and
// phaseOf(step) reads it; the boundary sits between detail and branching_complete, an unknown
// step reads as null, and the existing exports (stepNames, commitGateOf, PLAN_STEP_TABLE) keep
// their values.
// TL3 gap (what this test does NOT catch):
// - a consumer reading the phase column directly instead of through phaseOf.

const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
after(() => restore());

const F = require("./feature-2852-reset-allowance/fixture");
const TABLE = "hooks/workflow-state/step-table.js";
const table = () => F.mod(TABLE);
const phaseOf = () => F.need(TABLE, "phaseOf");

const PRE = ["workflow_init", "clarify_intent", "research", "outline", "detail"];
const IMPL = [
  "branching_complete", "write_tests", "review_tests", "write_code", "run_tests", "review_security",
  "docs", "review_docs", "push_branch", "user_verification", "merge_to_main", "cleanup",
  "pre_final_report_gate", "final_report",
];

caseBegin("every-step-has-a-phase", "hooks/workflow-state/step-table.js");
test("every step of stepNames() is pre-implementation or implementation", () => {
  const p = phaseOf();
  for (const step of table().stepNames()) {
    assert.ok(["pre-implementation", "implementation"].includes(p(step)), `${step}: ${p(step)}`);
  }
});
test("phaseOf answers the expected phase for each step", () => {
  const p = phaseOf();
  for (const step of PRE) assert.strictEqual(p(step), "pre-implementation", step);
  for (const step of IMPL) assert.strictEqual(p(step), "implementation", step);
});
caseEnd();

caseBegin("phase-boundary", "hooks/workflow-state/step-table.js");
test("the boundary sits between detail and branching_complete, and phases never interleave", () => {
  const p = phaseOf();
  const names = table().stepNames();
  const firstImpl = names.findIndex((s) => p(s) === "implementation");
  assert.strictEqual(names[firstImpl - 1], "detail");
  assert.strictEqual(names[firstImpl], "branching_complete");
  for (let i = firstImpl; i < names.length; i++) assert.strictEqual(p(names[i]), "implementation", names[i]);
  for (let i = 0; i < firstImpl; i++) assert.strictEqual(p(names[i]), "pre-implementation", names[i]);
});
caseEnd();

caseBegin("unknown-step-is-null", "hooks/workflow-state/step-table.js");
test("an unknown, empty or missing step reads as null", () => {
  const p = phaseOf();
  for (const v of ["bogus_step", "", undefined, null, 3, "WRITE_CODE"]) {
    assert.strictEqual(p(v), null, `phaseOf(${JSON.stringify(v)})`);
  }
});
caseEnd();

caseBegin("existing-exports-unchanged", "hooks/workflow-state/step-table.js");
test("stepNames keeps its order", () => {
  assert.deepStrictEqual(table().stepNames(), PRE.concat(IMPL));
});
test("commitGateOf keeps its values", () => {
  const want = {
    workflow_init: "required", clarify_intent: "required", research: "exempt", outline: "required",
    detail: "required", branching_complete: "required", write_tests: "required", review_tests: "required",
    write_code: "required", run_tests: "required", review_security: "required", docs: "required",
    review_docs: "required", push_branch: "exempt", user_verification: "deferred-in-worktree",
    merge_to_main: "exempt", cleanup: "deferred-in-worktree", pre_final_report_gate: "exempt", final_report: "exempt",
  };
  const got = {};
  for (const step of table().stepNames()) got[step] = table().commitGateOf(step);
  assert.deepStrictEqual(got, want);
  assert.strictEqual(table().commitGateOf("bogus_step"), null);
});
test("isStepRequired still drops push_branch and cleanup on the direct path only", () => {
  const t = table();
  const direct = { deliverableType: "wf-code", deliveryPath: "direct" };
  const pr = { deliverableType: "wf-code", deliveryPath: "pull_request" };
  assert.deepStrictEqual([t.isStepRequired(direct, "push_branch"), t.isStepRequired(direct, "cleanup")], [false, false]);
  assert.deepStrictEqual([t.isStepRequired(pr, "push_branch"), t.isStepRequired(pr, "cleanup")], [true, true]);
});
caseEnd();

caseBegin("plan-step-table-unchanged", "hooks/workflow-state/plan-step-table.js");
test("PLAN_STEP_TABLE keeps its rows", () => {
  const { PLAN_STEP_TABLE } = F.mod("hooks/workflow-state/plan-step-table.js");
  const pick = (r) => [r.suffix, r.sentinel, r.confirmFlag, r.offWaivable, r.nextSkill];
  assert.deepStrictEqual(Object.keys(PLAN_STEP_TABLE), ["clarify_intent", "outline", "detail"]);
  assert.deepStrictEqual(pick(PLAN_STEP_TABLE.clarify_intent), ["intent", "WORKFLOW_CONFIRM_INTENT", "CONFIRM_INTENT", false, "make-outline-plan"]);
  assert.deepStrictEqual(pick(PLAN_STEP_TABLE.outline), ["outline", "WORKFLOW_CONFIRM_OUTLINE", "CONFIRM_OUTLINE", true, "make-detail-plan"]);
  assert.deepStrictEqual(pick(PLAN_STEP_TABLE.detail), ["detail", "WORKFLOW_CONFIRM_DETAIL", "CONFIRM_DETAIL", true, "write-tests"]);
});
caseEnd();
