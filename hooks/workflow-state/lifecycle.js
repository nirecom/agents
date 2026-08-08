"use strict";
// SSOT for "did THIS session genuinely start the workflow?" — an allow-list
// on the settling event's origin, not a denylist on session-inherit, so
// cross-session state replay never counts as adoption. Rationale + full
// origin list: docs/architecture/claude-code/workflow.md#exemptions (#1794).
const { readState, isGenuineProvenance } = require("./state-io");

// Event kinds that can represent a step settlement worth adopting. Currently
// only step_status — other kinds don't carry a completion/skip fact.
const ADOPTION_EVENT_KINDS = ["step_status"];

// Origins representing a genuine, THIS-SESSION action settling a step. See
// docs/architecture/claude-code/workflow.md#exemptions for what each origin
// is and why session-inherit / next-step auto-persist origins are excluded.
const ADOPTION_ORIGINS = ["mark-step", "migration-v1-to-v2", "reset-sentinel"];

function isSettledStatus(status) {
  return status === "complete" || status === "skipped";
}

// Is `event` a step_status event this predicate should adopt as evidence the
// current session genuinely started the workflow itself?
function isAdoptionEvent(event) {
  if (!event || typeof event !== "object") return false;
  if (ADOPTION_EVENT_KINDS.indexOf(event.kind) === -1) return false;
  if (!isGenuineProvenance(event.provenance)) return false;
  if (!isSettledStatus(event.status)) return false;
  if (ADOPTION_ORIGINS.indexOf(event.origin) === -1) return false;
  return true;
}

// hasSelfRecordedStepSettlement(state): true when the event stream contains
// at least one adoption-worthy event (see isAdoptionEvent). Total function —
// never throws. Fail-CLOSED: any malformed/missing input reads as false, same
// direction as the old isWorkflowStarted contract.
function hasSelfRecordedStepSettlement(state) {
  try {
    if (!state || typeof state !== "object") return false;
    const events = state.events;
    if (!Array.isArray(events) || events.length === 0) return false;
    for (const event of events) {
      if (isAdoptionEvent(event)) return true;
    }
    return false;
  } catch (_e) {
    return false;
  }
}

// isWorkflowStarted(sid): true when the session's own event stream shows a
// genuine, adoption-worthy step settlement. Total function — never throws.
// Missing state / read failure / wrong shape → false. fail-CLOSED ("cannot
// prove started" = "not started"). Every consumer uses this in the
// suppression direction, so the predicate's fail-CLOSED matches the guard's
// overall fail-OPEN (see detail.md 3-5).
function isWorkflowStarted(sid) {
  try {
    const state = readState(sid);
    return hasSelfRecordedStepSettlement(state);
  } catch (_e) {
    return false;
  }
}

module.exports = {
  isWorkflowStarted,
  hasSelfRecordedStepSettlement,
  ADOPTION_EVENT_KINDS,
  ADOPTION_ORIGINS,
  isAdoptionEvent,
};
