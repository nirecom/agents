#!/usr/bin/env node
"use strict";
// Fixture generator for tests/feature-1733-state-event-stream/* (NOT a test itself).
//
//   node mk-v1.js <preset> > <state-file>
//
// Presets emit schema-v1 state files (the pre-#1733 shape) so the v1->v2 lazy
// migration can be exercised against realistic input. Every preset is a pure
// function of the preset name — no clock, no randomness — so a migration result
// can be compared byte-for-byte across two runs (idempotency cases).
//
//   annotations  every annotation key that really occurs on a step entry
//                (token, wsid, warnings_summary, warnings_accepted_reason,
//                 invalidate_reason, skip_reason, skip_verdict, skip_judgment,
//                 reset_reason) + an unknown key + a null-valued key +
//                 a `started_at` that must be discarded + a pending/updated_at-null
//                 entry carrying skip_verdict (must NOT be dropped).
//   ordering     insertion order deliberately disagrees with `updated_at` order,
//                plus an empty pending entry (dropped) and a non-pending entry with
//                updated_at:null (backfilled + at_estimated).
//   toplevel     timestamped top-level facts: worktree_entered_at / worktree_exited_at,
//                session_model, complexity_evaluation, plan_approvals.
//
// Fixed timestamps keep every assertion deterministic.

const CREATED = "2026-06-20T09:00:00.000Z";

function base(extra) {
  return Object.assign(
    {
      version: 1,
      session_id: "genv1",
      created_at: CREATED,
      workflow_type: "wf-code",
      closes_issues: [1733],
      last_pushed_sha: null,
      git_branch: "feature/from-v1",
      cwd: "C:\\git\\agents",
      is_bugfix: false,
    },
    extra
  );
}

const PRESETS = {
  annotations: () =>
    base({
      steps: {
        // Every real annotation key on one entry. `started_at` must be discarded.
        review_tests: {
          status: "complete",
          updated_at: "2026-06-20T10:00:00.000Z",
          started_at: "2026-06-20T09:59:00.000Z",
          token: "tok-abc",
          wsid: "wsid-abc",
          warnings_summary: "2 advisory findings",
          warnings_accepted_reason: "accepted by user",
          invalidate_reason: null,
          future_field: "unknown-key-must-survive",
        },
        research: {
          status: "skipped",
          updated_at: "2026-06-20T10:05:00.000Z",
          skip_reason: "no research needed",
        },
        // pending + updated_at:null but carrying skip_verdict — must NOT be dropped.
        review_security: {
          status: "pending",
          updated_at: null,
          skip_verdict: {
            verdict: "skip",
            reason: "no security surface",
            recorded_at: "2026-06-20T10:07:30.000Z",
          },
        },
        outline: {
          status: "complete",
          updated_at: "2026-06-20T10:10:00.000Z",
          skip_judgment: {
            decision: "proceed",
            recorded_at: "2026-06-20T10:09:00.000Z",
          },
          reset_reason: "post-merge",
        },
      },
    }),

  ordering: () =>
    base({
      steps: {
        // Insertion order (detail, workflow_init, clarify_intent) disagrees with
        // updated_at order (workflow_init, clarify_intent, detail).
        detail: { status: "complete", updated_at: "2026-06-20T12:00:00.000Z" },
        workflow_init: { status: "complete", updated_at: "2026-06-20T10:00:00.000Z" },
        clarify_intent: { status: "complete", updated_at: "2026-06-20T11:00:00.000Z" },
        // non-pending with no timestamp -> backfilled + at_estimated, sorted first.
        docs: { status: "complete", updated_at: null },
        // empty pending -> dropped entirely.
        cleanup: { status: "pending", updated_at: null },
      },
    }),

  toplevel: () =>
    base({
      steps: {
        workflow_init: { status: "complete", updated_at: "2026-06-20T10:00:00.000Z" },
        outline: { status: "complete", updated_at: "2026-06-20T10:30:00.000Z" },
        detail: { status: "complete", updated_at: "2026-06-20T10:40:00.000Z" },
      },
      worktree_entered_at: "2026-06-20T10:15:00.000Z",
      worktree_exited_at: "2026-06-20T13:15:00.000Z",
      session_model: { id: "claude-opus-5", source: "transcript", recorded_at: "2026-06-20T09:01:00.000Z" },
      complexity_evaluation: {
        level: "high",
        signals: ["S1-multi-file", "S2-architecture"],
        recorded_at: "2026-06-20T09:02:00.000Z",
      },
      plan_approvals: {
        outline: {
          source: "confirm-sentinel",
          reason: "approved",
          artifact_sha256: "a".repeat(64),
          artifact_session_id: "genv1",
          artifact_hash_status: "verified",
          recorded_at: "2026-06-20T10:29:00.000Z",
        },
        detail: {
          source: "confirm-sentinel",
          reason: "approved",
          artifact_sha256: "b".repeat(64),
          artifact_session_id: "genv1",
          artifact_hash_status: "verified",
          recorded_at: "2026-06-20T10:39:00.000Z",
        },
      },
    }),
};

// ── presets whose defining property is what they OMIT or how they collide ──────
//
// unversioned: a state file written before `version` was introduced. It is v1 by
//   content and carries no marker at all, so a migration that dispatches on
//   `state.version === 1` skips it and hands v1 data to v2 readers. Every file on a
//   long-lived installation predates the marker, which makes this the most common
//   input in the field and the one most easily missed in a fixture set where every
//   fixture says `"version": 1`.
PRESETS.unversioned = () => {
  const s = base({
    steps: {
      workflow_init: { status: "complete", updated_at: "2026-06-20T10:00:00.000Z" },
      research: { status: "complete", updated_at: "2026-06-20T10:20:00.000Z", token: "tok-unversioned" },
      docs: { status: "pending", updated_at: null },
    },
  });
  delete s.version;
  return s;
};

// tiebreak: four entries sharing the EXACT same `updated_at`, listed in the reverse of
//   the order the migration must produce. Insertion order and the required order are
//   therefore in direct opposition: a sort that quietly relies on Object.keys order (or
//   on a non-stable comparator) produces the input order and fails. The required order
//   is at ascending, then at_estimated first, then VALID_STEPS index, then kind
//   (step_status before step_annotation), then STEP_ANNOTATION_KEYS index.
//   `created_at` is deliberately set to the SAME instant, so the backfilled entry
//   (updated_at: null, stamped with created_at) lands inside the equal-`at` group and
//   the at_estimated-first rule actually has something to order.
PRESETS.tiebreak = () =>
  base({
    created_at: "2026-06-20T11:00:00.000Z",
    steps: {
      // Reverse VALID_STEPS order on purpose: review_tests(7) .. workflow_init(0).
      review_tests: {
        status: "complete",
        updated_at: "2026-06-20T11:00:00.000Z",
        // Reverse annotation-key order too: wsid(1) after token(0) in the table.
        wsid: "wsid-tie",
        token: "tok-tie",
      },
      run_tests: { status: "complete", updated_at: "2026-06-20T11:00:00.000Z" },
      detail: { status: "complete", updated_at: "2026-06-20T11:00:00.000Z" },
      workflow_init: { status: "complete", updated_at: "2026-06-20T11:00:00.000Z" },
      // Same instant, but no timestamp of its own: at_estimated sorts it ahead of the
      // whole equal-`at` group even though `created_at` is what it is stamped with.
      clarify_intent: { status: "complete", updated_at: null },
    },
  });

const preset = process.argv[2];
if (!PRESETS[preset]) {
  process.stderr.write(
    "mk-v1.js: unknown preset " + JSON.stringify(preset) + " (want one of " + Object.keys(PRESETS).join(", ") + ")\n"
  );
  process.exit(2);
}
process.stdout.write(JSON.stringify(PRESETS[preset](), null, 2));
