"use strict";
// Delivery-boundary reset of user_verification after a successful merge-class
// Bash operation (#2527 3-2). A protected push resets post-push; a gh / glab
// merge resets post-merge. One appendEvents builder judges the projected state
// inside the lock, so a repeat of the same event (or a reset settleMergeToMain
// already wrote) appends nothing.

const { isDeliveryBoundaryReset } = require("../workflow-state/effective-state/delivery-boundary");

const RESET_REASON_BY_KIND = Object.freeze({
  "git-push-protected": "post-push",
  "gh-pr-merge": "post-merge",
  "glab-mr-merge": "post-merge",
});

const LABEL_BY_KIND = Object.freeze({
  "git-push-protected": "protected push",
  "gh-pr-merge": "gh pr merge",
  "glab-mr-merge": "glab mr merge",
});

// → the hook message for this reset (success, idempotent no-op, or failure).
function resetUserVerificationForDelivery(sessionId, kind) {
  const reason = RESET_REASON_BY_KIND[kind];
  const label = LABEL_BY_KIND[kind] || kind;
  if (!reason) return `workflow-mark: ${label} detected — unknown merge kind, nothing reset.`;
  let wrote = false;
  try {
    const { appendEvents } = require("../workflow-state/state-io/events");
    appendEvents(sessionId, (_events, projected) => {
      const uv = projected && projected.steps && projected.steps.user_verification;
      if (isDeliveryBoundaryReset(uv)) return [];
      wrote = true;
      const base = { step: "user_verification", provenance: "observed", origin: "workflow-mark-delivery" };
      return [
        Object.assign({ kind: "step_status", status: "pending" }, base),
        Object.assign({ kind: "step_annotation", key: "reset_reason", value: reason }, base),
      ];
    });
  } catch (e) {
    return `workflow-mark: ${label} detected — user_verification reset FAILED: ${e.message}`;
  }
  return wrote
    ? `workflow-mark: ${label} detected — user_verification reset to pending (${reason}).`
    : `workflow-mark: ${label} detected — user_verification already reset (${reason}); nothing written.`;
}

module.exports = { resetUserVerificationForDelivery, RESET_REASON_BY_KIND };
