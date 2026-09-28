"use strict";
// The single gate in front of the handoff writer (#2430): flush, procedure-point
// and auto-record writes all pass through here, so "outside the workflow active
// period nothing is recorded" holds for every origin at once (CPR-ORTH).
//
// Named exception: hooks/workflow-gate/handoff-record.js recordGateBlock() keeps
// calling appendHandoffEntry directly (gate-block path unchanged by #2430).

const { appendHandoffEntry } = require("./handoff-artifact");
const { isWorkflowActivePeriod } = require("./workflow-active-period");

// Returns {written, reason}; reason "inactive" when gated out. Never throws.
// options.activeBeforeEvent: the caller evaluated the gate itself before an event
// that may end the active period (a RESET_FROM rollback), and it was true.
function appendHandoffEntryIfActive(sid, entry, options) {
  try {
    const activeBefore = !!options && options.activeBeforeEvent === true;
    if (!activeBefore && !isWorkflowActivePeriod(sid)) return { written: false, reason: "inactive" };
    return appendHandoffEntry(sid, entry);
  } catch (_e) {
    return { written: false, reason: "io" };
  }
}

module.exports = { appendHandoffEntryIfActive };
