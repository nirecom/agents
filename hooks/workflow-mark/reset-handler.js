"use strict";
// Handles RESET_FROM_{step} sentinels, which roll back workflow state to a
// specified step (marking that step and all subsequent steps as pending).
//
// Since #1733 the rollback is an APPEND, not a rewrite: the reset is recorded as
// a `reset` anchor followed by the declared statuses it implies. Nothing before
// the anchor is touched, so the pre-reset history stays readable — and the
// top-level session settings (closes_issues, deliverable_type, session_model,
// last_pushed_sha) can no longer be dropped, because they are never rebuilt.

const { validateSkipReason } = require("./skip-reason");
const { RESET_FROM_RE_DQ, RESET_FROM_LOOKSLIKE_RE } = require("../lib/sentinel-patterns");
const { VALID_STEPS, readState, appendEvents, clearDeliveryProfile } = require("../workflow-state");
const {
  APPROVAL_GATED_STEPS,
  UnapprovedCompletionError,
  evaluateCompletionApproval,
  recoveryFor,
} = require("../workflow-state/completion-approval");
const { recordRiskSignal } = require("../lib/risk-signal");

const ORIGIN = "reset-sentinel";

// The full event batch a reset from `fromStep` implies, in audit order.
function buildResetEvents(fromStep, rawReason) {
  const fromIndex = VALID_STEPS.indexOf(fromStep);
  const events = [
    { kind: "reset", from_step: fromStep, reason: rawReason, provenance: "declared", origin: ORIGIN },
  ];

  for (let i = 0; i < fromIndex; i++) {
    events.push({
      kind: "step_status",
      step: VALID_STEPS[i],
      status: "complete",
      provenance: "declared",
      origin: ORIGIN,
    });
  }

  // Everything from the target onward returns to a clean pending: the annotations
  // are cleared EXPLICITLY (a tombstone event) rather than by rebuilding the step
  // object, so the values they carried stay in the stream.
  for (let i = fromIndex; i < VALID_STEPS.length; i++) {
    events.push({ kind: "step_annotations_cleared", step: VALID_STEPS[i], provenance: "declared", origin: ORIGIN });
    events.push({
      kind: "step_status",
      step: VALID_STEPS[i],
      status: "pending",
      provenance: "declared",
      origin: ORIGIN,
    });
  }

  return events;
}

// Approving the rollback is not approving the plans it re-completes (#2709): every gated step
// before the target must already hold a verified approval, whatever its current status — a
// complete step whose artifact changed since approval is refused too. Throws
// UnapprovedCompletionError for the first one that does not; CONFIRM_<STAGE>=off waivers are
// honoured here and stamped as confirm-flag-off by the ordinary completion boundary.
function assertPriorGatesApproved(sessionId, fromStep, state) {
  const fromIndex = VALID_STEPS.indexOf(fromStep);
  for (const step of APPROVAL_GATED_STEPS) {
    if (VALID_STEPS.indexOf(step) >= fromIndex) continue;
    const verdict = evaluateCompletionApproval(sessionId, step, state);
    if (!verdict.approved) throw new UnapprovedCompletionError(step, verdict.code, recoveryFor(step));
  }
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

  const resetMatch = cmd.match(RESET_FROM_RE_DQ);

  // --- LOOKSLIKE early intercept: catches bare/malformed RESET_FROM forms ---
  if (!resetMatch && RESET_FROM_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed RESET_FROM — ` +
        `expected: echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }

  // --- RESET_FROM handler ---
  if (resetMatch) {
    const [, fromStep, rawReason] = resetMatch;

    const v = validateSkipReason(rawReason);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: RESET_FROM rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}: {better reason}>>"`
      );
      return true;
    }

    if (!VALID_STEPS.includes(fromStep)) {
      pushMessage(
        `workflow-mark: ERROR — unknown step "${fromStep}" for RESET_FROM; ` +
        `state NOT changed. Valid steps: ${VALID_STEPS.join(", ")}.`
      );
      return true;
    }

    // #526: pushMessage retained (not signalFatal) — recovery UX must not hard-fail on null sessionId.
    if (!sessionId) {
      pushMessage(
        `workflow-mark: could not resolve session_id — reset-from "${fromStep}" NOT applied. ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}: {reason}>>"`
      );
      return true;
    }

    try {
      // A reset is a rollback of an EXISTING session. With no readable state there
      // is nothing to roll back, and materialising a file here would fabricate a
      // session whose whole history is a reset — or overwrite a corrupt file that
      // is the only remaining evidence of what went wrong. Fail closed in both.
      if (!readState(sessionId)) {
        pushMessage(
          `workflow-mark: reset-from "${fromStep}" NOT applied — no readable workflow state ` +
            `for this session.`
        );
        return true;
      }
      // Builder form: the batch is produced INSIDE the lock, so two resets racing
      // on the same file both land instead of one clobbering the other, and the
      // prior-gate verdict is taken on the very state the batch is appended to.
      try {
        appendEvents(sessionId, (_events, projection) => {
          // The evaluator resolves an ownerless inherited approval through upstream_session_id
          // and the event history, which the bare projection lacks.
          assertPriorGatesApproved(sessionId, fromStep,
            Object.assign({}, readState(sessionId), { events: _events }, projection));
          return buildResetEvents(fromStep, rawReason);
        });
      } catch (e) {
        if (!(e instanceof UnapprovedCompletionError)) throw e;
        pushMessage(
          `workflow-mark: RESET_FROM_${fromStep} refused — ${e.step} has no verified approval ` +
            `(${e.code}). ${e.recovery}`
        );
        return true;
      }
      // #2527 judgment D: re-opening branching_complete re-opens the delivery decision,
      // so the pinned profile is cleared for the re-completion to record afresh. A
      // reset from a later step keeps it.
      if (VALID_STEPS.indexOf(fromStep) <= VALID_STEPS.indexOf("branching_complete")) {
        try {
          clearDeliveryProfile(sessionId);
        } catch (e) {
          pushMessage(`workflow-mark: warning — reset applied but the delivery profile was NOT cleared: ${e.message}`);
        }
      }
      // The reset event above is the one record of the rollback (#2652); the state handoff
      // reader derives its entry from it. Only the omission-check risk stamp remains here.
      try {
        recordRiskSignal(sessionId, "reset-from");
      } catch (_e) { /* a lost stamp must not read as a failed reset */ }
    } catch (e) {
      pushMessage(`workflow-mark: reset-from failed — ${e.message}.`);
    }
    return true;
  }

  return false;
}

module.exports = { handle, buildResetEvents };
