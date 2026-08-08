"use strict";
// SSOT for "has the workflow actually started, in THIS session's own hands?" —
// judged by whether the state stream contains a genuinely-recorded step
// settlement from an adoption-worthy origin, not merely by whether some step
// is settled (#1794).
//
// Why this distinction matters: `hooks/session-start.js` may inherit a prior
// session's state wholesale, stamping every inherited event
// `origin: "session-inherit"` / `provenance: "backfilled"`. A brand-new
// session that never ran /workflow-init would otherwise look, to a naive
// "is workflow_init settled?" check, exactly like a session that did. Guards
// (C4 premature-stop, C2 supervisor) and this predicate must tell the two
// apart, or a self-contained/read-only session gets dragged into the
// workflow the user never asked to start (CPR-UO).
//
// This predicate is deliberately an ALLOW-LIST, not a denylist on
// origin=session-inherit: only origins known to represent the CURRENT
// session's own genuine action count. New adoption-worthy origins must be
// added to ADOPTION_ORIGINS explicitly (CPR-UNV — no implicit fallback).
const { readState, isGenuineProvenance } = require("./state-io");

// Named constant for the start boundary, same convention as SENTINEL_HANG_EXEMPT_STEPS.
const WORKFLOW_START_STEP = "workflow_init";

// Event kinds that can represent a step settlement worth adopting as "this
// session started the workflow itself". Currently only step_status — other
// kinds (annotations, worktree, etc.) don't carry a step completion/skip fact.
const ADOPTION_EVENT_KINDS = ["step_status"];

// Origins that represent a genuine, THIS-SESSION action settling a step.
// "mark-step" is the direct, user/skill-driven completion path
// (hooks/workflow-state/state-io/core.js markStep with no origin override,
// or an explicit skill-driven markStep call). "migration-v1-to-v2" is the
// legacy-schema upgrade path (hooks/workflow-state/state-io/migrations/v1-to-v2.js)
// — it is NOT session inheritance: it replays THIS session's own pre-#1733
// history into the new event-stream schema, so a v1 record that says
// "this session completed workflow_init" is exactly as genuine as a fresh
// mark-step call. "reset-sentinel" (hooks/workflow-mark/reset-handler.js) is
// the WORKFLOW_RESET_FROM_{step} sentinel path — it is `permissions.ask`
// (settings.json), so every reset-sentinel event required the user's
// explicit, THIS-session approval; that approval is exactly as genuine as a
// direct mark-step call, even though the rollback it produces sets later
// steps back to pending. Origins written by cross-session inheritance
// (session-inherit) or automated next-step auto-persist paths
// (next-step-evidence-resolution, next-step-recorded-verdict-skip) are
// deliberately EXCLUDED — see bin/workflow/lib/next-step/verdict.js header
// comment and docs/architecture/claude-code/workflow.md#exemptions for why
// next-step's own auto-persist does not count as "the user started the
// workflow" even though it IS a genuine, non-backfilled fact. Automated
// PostToolUse detection (hooks/workflow-run-tests.js) is likewise EXCLUDED
// via its own explicit origin override — a pattern-matched Bash command is
// not a deliberate workflow action.
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
  WORKFLOW_START_STEP,
};
