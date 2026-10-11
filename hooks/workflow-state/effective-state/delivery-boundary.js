"use strict";
// Delivery-boundary navigation stage of reconcileEffectiveState (#2527 3-2).
// A delivery operation (merge / protected push) resets user_verification to
// pending with a boundary reset_reason; that pending records a delivery that
// actually happened, so NAVIGATION treats it as settled and moves on to deliver
// instead of asking for approval again. Gates never pass the stage: for them the
// recorded pending stays pending, so the next commit or merge needs re-approval.

const DELIVERY_BOUNDARY_REASONS = Object.freeze(["post-merge", "post-push"]);

// Predicate on one recorded step entry (state.steps[step]).
function isDeliveryBoundaryReset(stepRecord) {
  return !!(
    stepRecord &&
    stepRecord.status === "pending" &&
    DELIVERY_BOUNDARY_REASONS.indexOf(stepRecord.reset_reason) !== -1
  );
}

function isRecordedSettled(entry) {
  return !!entry && (entry.status === "complete" || entry.status === "skipped");
}

// navigateBoundaryStatus(step, status, state) → "complete" when the navigate
// stage settles this step, else null. user_verification settles on any boundary
// reset; branching_complete settles on a post-push reset once deliver is recorded
// settled or user_verification carries a post-push boundary reset (the protected
// push landed before /deliver recorded deliver) — a direct delivery must not
// rewind navigation to branching and skip deliver's evidence check.
function navigateBoundaryStatus(step, status, state) {
  if (status !== "pending") return null;
  const steps = (state && state.steps) || {};
  const entry = steps[step] || null;
  if (step === "user_verification") {
    return isDeliveryBoundaryReset(entry) ? "complete" : null;
  }
  if (step === "branching_complete") {
    if (!entry || entry.reset_reason !== "post-push") return null;
    const uv = steps.user_verification;
    const pushedAfterApproval = isDeliveryBoundaryReset(uv) && uv.reset_reason === "post-push";
    return isRecordedSettled(steps.deliver) || pushedAfterApproval ? "complete" : null;
  }
  return null;
}

module.exports = { DELIVERY_BOUNDARY_REASONS, isDeliveryBoundaryReset, navigateBoundaryStatus };
