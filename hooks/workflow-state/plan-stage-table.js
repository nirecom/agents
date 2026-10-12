"use strict";
// hooks/workflow-state/plan-stage-table.js — the SSOT of the three approval-gated plan stages
// (#2277). Each row maps a workflow step to its plan artifact suffix, CONFIRM sentinel, CONFIRM_*
// flag, whether that flag may waive the gate, the skill that follows approval, and the H2
// sections left out of the approval digest. bin/workflow/lib/next-step/steps.js keeps the full
// step -> skill map; this table covers only the gated stages, and a test pins nextSkill to it.

const PLAN_STAGE_TABLE = Object.freeze({
  clarify_intent: Object.freeze({
    suffix: "intent",
    sentinel: "WORKFLOW_CONFIRM_INTENT",
    confirmFlag: "CONFIRM_INTENT",
    offWaivable: false,
    nextSkill: "make-outline-plan",
    // intent.md `## Issues` is the closes_issues SSOT and is rewritten by machine after approval.
    digestExcludes: Object.freeze(["Issues"]),
  }),
  outline: Object.freeze({
    suffix: "outline",
    sentinel: "WORKFLOW_CONFIRM_OUTLINE",
    confirmFlag: "CONFIRM_OUTLINE",
    offWaivable: true,
    nextSkill: "make-detail-plan",
    digestExcludes: Object.freeze([]),
  }),
  detail: Object.freeze({
    suffix: "detail",
    sentinel: "WORKFLOW_CONFIRM_DETAIL",
    confirmFlag: "CONFIRM_DETAIL",
    offWaivable: true,
    nextSkill: "write-tests",
    digestExcludes: Object.freeze([]),
  }),
});

function rowFor(step) {
  return Object.prototype.hasOwnProperty.call(PLAN_STAGE_TABLE, step) ? PLAN_STAGE_TABLE[step] : null;
}

// stepForSuffix("intent") -> "clarify_intent"; null for anything that is not a plan suffix.
function stepForSuffix(suffix) {
  for (const [step, row] of Object.entries(PLAN_STAGE_TABLE)) {
    if (row.suffix === suffix) return step;
  }
  return null;
}

// priorStepForSkill("agents:make-detail-plan") -> "outline": the gated step whose approval the
// skill needs. A plugin namespace prefix ("<ns>:") is accepted.
function priorStepForSkill(skill) {
  if (typeof skill !== "string" || !skill) return null;
  const bare = skill.slice(skill.lastIndexOf(":") + 1);
  for (const [step, row] of Object.entries(PLAN_STAGE_TABLE)) {
    if (row.nextSkill === bare) return step;
  }
  return null;
}

module.exports = { PLAN_STAGE_TABLE, rowFor, stepForSuffix, priorStepForSkill };
