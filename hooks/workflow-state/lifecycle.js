"use strict";
// SSOT for "did THIS session genuinely start the workflow?" — an allow-list
// on the settling event's origin, not a denylist on session-inherit, so
// cross-session state replay never counts as adoption. Rationale + full
// origin list: docs/architecture/claude-code/workflow.md#exemptions (#1794).
const { readState, isGenuineProvenance } = require("./state-io");
const {
  STEP_IN_FLIGHT_ALLOWLIST,
  STEP_IN_FLIGHT_TTL_MS,
  isStepInFlightCandidate,
  isFreshInFlightEntry,
} = require("../lib/step-in-flight-policy");

// Event kinds that can represent a step settlement worth adopting. Currently
// only step_status — other kinds don't carry a completion/skip fact.
const ADOPTION_EVENT_KINDS = ["step_status"];

// Origins representing a genuine, THIS-SESSION action settling a step. See
// docs/architecture/claude-code/workflow.md#exemptions for what each origin
// is and why session-inherit / next-step auto-persist origins are excluded.
const ADOPTION_ORIGINS = ["mark-step", "migration-v1-to-v2", "reset-sentinel"];

// Exact origin hooks/postuse-step-in-flight-mark.js passes to markStep for its
// WI-10 lookahead mark. Deliberately distinct from markStep's own default
// origin ("mark-step") — isLookaheadOnlyInFlight below keys on that gap.
const LOOKAHEAD_ORIGIN = "postuse-in-flight";

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

// How long a `write_code in_progress` record may keep C4 quiet. Same 4 hours as
// the retired TTL-based quiet-layer marker whose role this exemption inherits.
const WRITE_CODE_IN_FLIGHT_TTL_MS = 4 * 60 * 60 * 1000;

// isWriteCodeInFlight(sid): true when THIS session's `write_code` step is
// recorded `in_progress` and younger than the TTL. Total — never throws.
// Deliberately scoped to `write_code` ALONE, and kept as its own predicate even
// after #2013 added the allowlist-scoped sibling below (CPR-UNV: the exception
// stays named and bounded). Fail-CLOSED via isFreshInFlightEntry.
// Detail: docs/architecture/claude-code/workflow.md#exemptions.
function isWriteCodeInFlight(sid) {
  try {
    const state = readState(sid);
    const entry = state && state.steps && state.steps.write_code;
    return isFreshInFlightEntry(entry, WRITE_CODE_IN_FLIGHT_TTL_MS);
  } catch (_e) {
    return false;
  }
}

// isStepInFlight(sid, step): true when `step` is an ALLOWLISTED delegated step
// (step-in-flight-policy.js is the SSOT) whose record is `in_progress` and
// younger than the TTL. Sibling of isWriteCodeInFlight, not a generalisation:
// write_code sits outside the allowlist, so the two disagree for a write_code
// fixture (#2013). Total — never throws.
function isStepInFlight(sid, step) {
  try {
    if (!isStepInFlightCandidate(step)) return false;
    const state = readState(sid);
    const entry = state && state.steps && state.steps[step];
    return isFreshInFlightEntry(entry, STEP_IN_FLIGHT_TTL_MS);
  } catch (_e) {
    return false;
  }
}

// anyStepInFlight(sid): the NAME of the step this session is currently waiting
// on, or null — consumers report which dispatch they are deferring to. It spans
// BOTH in-flight predicates because a consumer asking "is a unit of delegated
// work running?" gets one answer, while the two predicates stay separately
// addressable for callers that mean one of them specifically. Never throws.
function anyStepInFlight(sid) {
  try {
    const state = readState(sid);
    if (!state || !state.steps) return null;
    for (const step of STEP_IN_FLIGHT_ALLOWLIST) {
      if (isFreshInFlightEntry(state.steps[step], STEP_IN_FLIGHT_TTL_MS)) return step;
    }
    if (isFreshInFlightEntry(state.steps.write_code, WRITE_CODE_IN_FLIGHT_TTL_MS)) return "write_code";
    return null;
  } catch (_e) {
    return null;
  }
}

// isLookaheadOnlyInFlight(sid, step): true when the LAST step_status event
// recorded for `step` came from the WI-10 lookahead mark specifically
// (origin === LOOKAHEAD_ORIGIN), not from any other marking path. Total —
// never throws, fail-CLOSED to false on any error or absent evidence (#2169).
function isLookaheadOnlyInFlight(sid, step) {
  try {
    const state = readState(sid);
    if (!state || !Array.isArray(state.events)) return false;
    for (let i = state.events.length - 1; i >= 0; i--) {
      const e = state.events[i];
      if (e && e.kind === "step_status" && e.step === step) {
        return e.origin === LOOKAHEAD_ORIGIN;
      }
    }
    return false;
  } catch (_e) {
    return false;
  }
}

module.exports = {
  isWorkflowStarted,
  WRITE_CODE_IN_FLIGHT_TTL_MS,
  isWriteCodeInFlight,
  isStepInFlight,
  anyStepInFlight,
  hasSelfRecordedStepSettlement,
  ADOPTION_EVENT_KINDS,
  ADOPTION_ORIGINS,
  isAdoptionEvent,
  LOOKAHEAD_ORIGIN,
  isLookaheadOnlyInFlight,
};
