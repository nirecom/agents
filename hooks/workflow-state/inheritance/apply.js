"use strict";
// The ONE execution point for applying a donor's work record to an heir (#1305).
//
// Moved out of hooks/session-start.js because inheritance now has TWO entry
// points — the automatic lineage path in the SessionStart hook, and the explicit
// bin/workflow/adopt-session-state CLI used for crash-resume. Both must append
// byte-identical streams, which is only guaranteed if there is exactly one
// implementation (CPR-SSOT).

const { appendEvents, VALID_STEPS } = require("../state-io");
const { convertV1AnnotationsToEvents } =
  require("../state-io/migrations/v1-to-v2");
const { APPROVAL_GATED_STEPS } = require("../completion-approval");

const INHERIT_ORIGIN = "session-inherit";

// applyInheritance(sessionId, createdAt, donor)
//
// Carries a prior session's WORK RECORD into a fresh session as ONE append-only
// batch (#1733). Pre-#1733 this was a blind deep copy of the donor's `steps` map;
// expressing it as events makes three things explicit that the copy hid:
//
//   * provenance:"backfilled" + inherited_from — an inherited `complete` is not a
//     completion this session observed. Downstream genuineness checks can finally
//     tell the two apart (effective-state.hasGenuineRecordedComplete).
//   * every event is stamped `at = createdAt` — the heir's timeline never reaches
//     back into the donor's. The deliberate consequence is that an inherited step's
//     `updated_at` is now the heir's created_at rather than the donor's original.
//   * cleanup (#772) is RESET rather than carried: its donor annotations are
//     dropped by an explicit tombstone, not merely shadowed.
//
// What is NOT inherited: session_model, complexity_evaluation, worktree_*,
// git_branch/cwd, workflow_type, closes_issues, last_pushed_sha. Each is a fact
// about the donor session itself, not about the work.
function applyInheritance(sessionId, createdAt, donor) {
  const donorSid = (donor && donor.session_id) || null;
  const donorSteps = (donor && donor.steps) || {};
  const donorApprovals = (donor && donor.plan_approvals) || null;

  const stamp = (event) =>
    Object.assign({}, event, {
      at: createdAt,
      provenance: "backfilled",
      origin: INHERIT_ORIGIN,
      inherited_from: donorSid,
    });

  const build = () => {
    const events = [];

    for (const step of VALID_STEPS) {
      // cleanup is handled below — its donor record is discarded wholesale.
      if (step === "cleanup") continue;
      const entry = donorSteps[step];
      if (!entry || typeof entry !== "object") continue;

      if (typeof entry.status === "string" && entry.status !== "pending") {
        events.push(stamp({ kind: "step_status", step, status: entry.status }));
      }
      // Annotations travel even on a PENDING step (a reset_reason explains why the
      // step was rewound and is lost if only non-pending steps are carried).
      // convertV1AnnotationsToEvents owns which entry fields ARE annotations —
      // the same conversion the v1->v2 migration performs (CPR-E2C); only the
      // stamping differs, so the two can never disagree about the field set.
      for (const converted of convertV1AnnotationsToEvents(step, entry, { createdAt })) {
        events.push(
          stamp({ kind: "step_annotation", step, key: converted.key, value: converted.value })
        );
      }
    }

    // #772: cleanup must never inherit as already-done. The three events are one
    // unit: discard the donor's notes, record the reset, state why.
    events.push(stamp({ kind: "step_annotations_cleared", step: "cleanup" }));
    events.push(stamp({ kind: "step_status", step: "cleanup", status: "skipped" }));
    events.push(
      stamp({
        kind: "step_annotation",
        step: "cleanup",
        key: "skip_reason",
        value: "inherited-from-prior-session",
      })
    );

    // #1133: an inherited outline/detail `complete` is a pending->complete
    // transition for the NEW session, so the donor's approval must land in the
    // SAME batch or the completion-boundary invariant refuses the whole append.
    // The record stays bound to the artifact it was approved against
    // (<owner-sid>-<step>.md) via artifact_session_id.
    if (donorApprovals && typeof donorApprovals === "object") {
      // Iterate VALID_STEPS, not the donor's keys: the donor is a FOREIGN session's
      // file from the shared workflow dir, and an out-of-vocabulary key would make
      // validateEvent throw, aborting inheritance and leaving this session with no
      // state file at all. Skip what we don't recognize; never let it wedge us.
      for (const step of VALID_STEPS) {
        const rec = donorApprovals[step];
        if (!rec || typeof rec !== "object") continue;
        events.push(
          stamp({
            kind: "plan_approval",
            step,
            source: rec.source !== undefined ? rec.source : null,
            reason: rec.reason !== undefined ? rec.reason : null,
            artifact_sha256: rec.artifact_sha256 !== undefined ? rec.artifact_sha256 : null,
            artifact_session_id: rec.artifact_session_id || donorSid || null,
            artifact_hash_status:
              rec.artifact_hash_status !== undefined ? rec.artifact_hash_status : null,
          })
        );
      }
    }

    return events;
  };

  // #1133 × #1305: a donor may predate plan_approvals entirely (or simply never
  // recorded one) while still holding outline/detail complete. Refusing that
  // batch would make inheritance impossible for exactly the sessions it exists
  // to rescue, so the boundary is crossed under the named `session-inherit`
  // token — which stamps an audit record rather than silently waiving anything.
  //
  // The token is offered ONLY when the donor holds NO record for any gated step
  // it is completing. A donor that HAS one is verified the normal way, so a
  // tampered or deleted artifact is still refused (#1133 G15f/G15h).
  const gatedCompleting = APPROVAL_GATED_STEPS.filter(
    (step) => donorSteps[step] && donorSteps[step].status === "complete"
  );
  const anyDonorRecord = gatedCompleting.some(
    (step) => donorApprovals && donorApprovals[step] && typeof donorApprovals[step] === "object"
  );
  const sanctioned =
    gatedCompleting.length > 0 && !anyDonorRecord ? "session-inherit" : null;

  // Builder form: the batch is produced INSIDE the lock, and `now` pins every
  // unstamped event to the heir's created_at.
  appendEvents(sessionId, build, {
    origin: INHERIT_ORIGIN,
    now: createdAt,
    sanctioned,
    reason: sanctioned
      ? `inherited from session ${donorSid || "(unknown)"} which recorded no plan approval`
      : null,
  });
}

module.exports = { INHERIT_ORIGIN, applyInheritance };
