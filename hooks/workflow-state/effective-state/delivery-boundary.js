"use strict";
// Delivery-boundary navigation stage of reconcileEffectiveState (#2527 3-2).
// A delivery operation (merge / protected push) resets user_verification to
// pending with a boundary reset_reason; that pending records a delivery that
// actually happened, so NAVIGATION treats it as settled and moves on to merge_to_main
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

function isWebMergeChannel(state, profile) {
  return require("../session-profile").releaseApprovalChannelOf(state, profile) === "web-merge";
}

function isRecordedSettled(entry) {
  return !!entry && (entry.status === "complete" || entry.status === "skipped");
}

// navigateBoundaryStatus(step, status, state[, profile]) → "complete" when the navigate
// stage settles this step, else null. user_verification settles on any boundary
// reset; branching_complete settles on a post-push reset once merge_to_main is recorded
// settled or user_verification carries a post-push boundary reset (the protected
// push landed before /merge-to-main recorded merge_to_main) — a direct delivery must not
// rewind navigation to branching and skip merge_to_main's evidence check.
// profile (optional, #2527 4-4): on the web-merge channel a boundary reset (e.g. post-push)
// precedes the human's merge, so user_verification settles only once merge_to_main is settled.
function navigateBoundaryStatus(step, status, state, profile) {
  if (status !== "pending") return null;
  const steps = (state && state.steps) || {};
  const entry = steps[step] || null;
  if (step === "user_verification") {
    if (!isDeliveryBoundaryReset(entry)) return null;
    if (profile && isWebMergeChannel(state, profile) && !isRecordedSettled(steps.merge_to_main)) return null;
    return "complete";
  }
  if (step === "branching_complete") {
    if (!entry || entry.reset_reason !== "post-push") return null;
    const uv = steps.user_verification;
    const pushedAfterApproval = isDeliveryBoundaryReset(uv) && uv.reset_reason === "post-push";
    return isRecordedSettled(steps.merge_to_main) || pushedAfterApproval ? "complete" : null;
  }
  return null;
}

module.exports = { DELIVERY_BOUNDARY_REASONS, isDeliveryBoundaryReset, navigateBoundaryStatus };
