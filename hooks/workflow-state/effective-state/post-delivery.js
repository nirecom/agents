"use strict";
// Post-delivery judgment on the RECORDED step statuses (#2796): once a session's change is
// delivered, its complete plan stages no longer re-evaluate against main's moving glossary.
// Reads the raw record, never the table-skip projection, so a WF-META session whose
// merge_to_main is only table-skipped stays pre-delivery. Fails toward false.

const { TERMINAL_STEPS } = require("../state-io");

// recordedStatusOf(state, step) → the recorded status of `step`; unrecorded reads as "pending".
function recordedStatusOf(state, step) {
  const entry = state && state.steps && state.steps[step];
  return entry && entry.status ? entry.status : "pending";
}

// isPostDeliverySession(state) → true when a terminal step is recorded complete or
// merge_to_main is recorded settled (complete or skipped).
function isPostDeliverySession(state) {
  try {
    if (TERMINAL_STEPS.some((step) => recordedStatusOf(state, step) === "complete")) return true;
    const merge = recordedStatusOf(state, "merge_to_main");
    return merge === "complete" || merge === "skipped";
  } catch (_) {
    return false;
  }
}

module.exports = { recordedStatusOf, isPostDeliverySession };
