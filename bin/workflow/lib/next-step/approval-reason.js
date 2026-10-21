"use strict";
// Approval-wait reason for next-step (#2277 S14). A session that ran past an
// unapproved gated stage still has later steps recorded complete, so verdict.js
// asks here BEFORE its inconsistency scan: the answer is "re-present and wait
// for the user's approval", never an abort. Kept out of verdict.js for size.

const { hasCompletionEvidence } = require("../../../../hooks/workflow-state/evidence-resolver");
const {
  isApprovalGatedStep,
  evaluateCompletionApproval,
  confirmSentinelFor,
} = require("../../../../hooks/workflow-state/completion-approval");

// #2529: approved yet still pending because the glossary check is not complete. The recovery
// text is the per-code one record.js gives the completion refusal (SSOT).
function glossaryWaitFor(sid, step, state) {
  const { evaluateGlossaryCheck } = require("../../../../hooks/workflow-state/glossary-check/record");
  const v = evaluateGlossaryCheck(sid, step, state, {});
  if (v.ok) return null;
  const entry = state && state.steps && state.steps[step];
  const recorded = entry && entry.status === "complete"
    ? " " + step + " is already recorded complete: it reads complete again by itself once the check passes."
    : "";
  const hint = ("The " + step + " plan is approved but its glossary check is not complete (" + v.code + "): " +
    ((v.detail && v.detail.recovery) || "") + recorded).replace(/'/g, "");
  return { reason: v.code + ": " + step, hint };
}

// approvalWaitFor(sid, currentStep, state) -> {reason, hint} | null.
// The hint is emitted inside single quotes, so it must contain none.
function approvalWaitFor(sid, currentStep, state) {
  try {
    if (!isApprovalGatedStep(currentStep)) return null;
    if (!hasCompletionEvidence(currentStep, sid, { state })) return null;
    if (evaluateCompletionApproval(sid, currentStep, state).approved) return glossaryWaitFor(sid, currentStep, state);
    const sentinel = confirmSentinelFor(currentStep);
    const hint =
      "The " + currentStep + " plan has no approval on record. Resume the named skill at its confirm " +
      "step only; do not re-run its planner or rewrite the plan. Re-present the current plan and end " +
      "that presentation turn with the plan-link line (bin/plan-link). After the user replies with " +
      "approval, emit echo \"<<" + sentinel + ": {summary}>>\" on its own. If the user denies or asks " +
      "for changes, revise the plan and wait for the fix to be approved.";
    return { reason: "awaiting-plan-approval: " + currentStep, hint };
  } catch (_e) {
    return null;
  }
}

module.exports = { approvalWaitFor };
