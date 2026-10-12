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

// approvalWaitFor(sid, currentStep, state) -> {reason, hint} | null.
// The hint is emitted inside single quotes, so it must contain none.
function approvalWaitFor(sid, currentStep, state) {
  try {
    if (!isApprovalGatedStep(currentStep)) return null;
    if (!hasCompletionEvidence(currentStep, sid, { state })) return null;
    if (evaluateCompletionApproval(sid, currentStep, state).approved) return null;
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
