"use strict";
// settleMergeToMain — the single writer of a merge_to_main completion (#2527 3-2b).
// merge_to_main complete and the user_verification boundary reset go out in ONE
// appendEvents builder, so no reader can see a delivered session whose approval
// still looks live (and a fresh approval is demanded before the next delivery).
// The builder judges the projected state inside the lock, so a repeat call, or a
// hook that already reset user_verification, adds nothing.

const { DELIVERY_BOUNDARY_REASONS, isDeliveryBoundaryReset } = require("./effective-state/delivery-boundary");

// A merged PR resets post-merge; a push straight to the default branch (the
// direct path, and a bootstrap push to an empty remote) resets post-push.
function deliveryKindFor(deliveryPath) {
  return deliveryPath === "pull_request" ? "post-merge" : "post-push";
}

function settleMergeToMain(sessionId, opts) {
  const o = opts || {};
  if (DELIVERY_BOUNDARY_REASONS.indexOf(o.kind) === -1) {
    throw new Error(`settleMergeToMain: kind must be one of ${DELIVERY_BOUNDARY_REASONS.join("/")} (got ${o.kind})`);
  }
  const provenance = typeof o.provenance === "string" ? o.provenance : "observed";
  const origin = typeof o.origin === "string" ? o.origin : "delivery-settle";
  const extraFields = o.extraFields && typeof o.extraFields === "object" ? o.extraFields : {};
  const { appendEvents, RESERVED_ANNOTATION_KEYS } = require("./state-io/events");
  let written = 0;
  appendEvents(sessionId, (_events, projected) => {
    const steps = (projected && projected.steps) || {};
    const out = [];
    const mergePending = !steps.merge_to_main || steps.merge_to_main.status !== "complete";
    if (mergePending) {
      out.push({ kind: "step_status", step: "merge_to_main", status: "complete", provenance, origin });
    }
    if (!isDeliveryBoundaryReset(steps.user_verification)) {
      out.push({ kind: "step_status", step: "user_verification", status: "pending", provenance, origin });
      out.push({
        kind: "step_annotation", step: "user_verification", key: "reset_reason", value: o.kind, provenance, origin,
      });
    }
    // merge_to_main annotations trail the three settle events so they stay contiguous.
    for (const key of mergePending ? Object.keys(extraFields) : []) {
      if (RESERVED_ANNOTATION_KEYS.includes(key)) continue;
      const value = extraFields[key] === undefined ? null : extraFields[key];
      out.push({ kind: "step_annotation", step: "merge_to_main", key, value, provenance, origin });
    }
    written = out.length;
    return out;
  }, o.lockOpts || {});
  return { written };
}

module.exports = { settleMergeToMain, deliveryKindFor };
