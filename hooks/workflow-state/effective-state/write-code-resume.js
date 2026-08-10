"use strict";
// Stage 5 of reconcileEffectiveState: the write_code resume cascade.
//
// When `run_tests` records a FAILING outcome, every step that was settled
// BEFORE that failure signed off on code which is about to change. The cascade
// reopens those settlements (derived-only, never written to disk) so the
// session goes back through /write-code before it can commit.
//
// Split out of effective-state.js per rules/coding/file-split.md pattern A.
//
// Inputs: the trigger (`run_outcome`) and the seq values compared come from the
// RAW projection, not the derived one — the derived entry built by
// effective-state.js is deliberately minimal (`{ status, resolved_from, ... }`)
// and must not be widened to carry `updated_seq`, or this stage's read and the
// raw fact it depends on would drift apart. Only `status` itself comes from the
// derived side, respecting stages 1-4's prior masking.
//
// This cascade does not need a `provenance: "backfilled"` check: it answers "is
// this completion older than the observed failure?" (a seq comparison), not
// "did this session genuinely observe it?" (hasGenuineRecordedComplete's
// question, used elsewhere for resumability). Inherited and v1-migrated
// completions are masked automatically because they always carry a smaller
// seq than a later run_tests failure. The v2→v3 backfill (see
// state-io/migrations/v2-to-v3.js) is the one path that writes `write_code` at
// the tail of a stream with a larger seq, but it's inert here regardless: its
// trigger annotation (`run_outcome`) ships in the same schema version as the
// backfill itself, so a file eligible for backfilling can never carry a
// `run_outcome` yet. Any later failure appends after the backfilled record,
// restoring normal ordering.

// Outcomes that mean "the run reported a failure". Absent / null / "pass" do
// NOT fire the cascade — "no outcome recorded" is not evidence of failure.
const FAILING_RUN_OUTCOMES = ["fail", "timeout", "runner-error"];

const RESOLVED_FROM = "write-code-resumed";

// applyWriteCodeResume(steps, resolutions, state) → void
//
// Mutates the derived `steps` snapshot and the `resolutions` array in place.
// Never touches `state`, and never writes anything to disk: the mask is a
// read-time derivation, exactly like stages 1-4.
function applyWriteCodeResume(steps, resolutions, state) {
  // Lazy require avoids a load-time destructure capturing `undefined` when
  // this module is pulled in mid-cycle from state-io's own dependents.
  const { VALID_STEPS } = require("../state-io");
  const rawSteps = (state && state.steps) || {};
  const runTests = rawSteps.run_tests || {};

  if (FAILING_RUN_OUTCOMES.indexOf(runTests.run_outcome) === -1) return;

  // A non-finite baseline means we can't prove WHEN the failure happened, so
  // fall back to the fail-safe rule: everything downstream is stale.
  const rawResumeSeq = runTests.updated_seq;
  const resumeSeq = Number.isFinite(rawResumeSeq) ? rawResumeSeq : Infinity;

  const firstIndex = VALID_STEPS.indexOf("write_code");
  if (firstIndex === -1) return;

  const masked = [];
  for (let i = firstIndex; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    const derived = steps[step];
    if (!derived) continue;
    if (derived.status !== "complete" && derived.status !== "skipped") continue;

    // Numeric comparison only: with a finite baseline, an unknown step
    // position is left alone (can't prove it predates a known failure); with
    // an infinite baseline, every settled downstream step is masked.
    const stepSeq = (rawSteps[step] || {}).updated_seq;
    const stale = Number.isFinite(stepSeq) ? stepSeq < resumeSeq : resumeSeq === Infinity;
    if (!stale) continue;

    derived.status = "pending";
    derived.resolved_from = RESOLVED_FROM;
    masked.push(step);
  }

  // A masked step must not survive in `resolutions`, or verdict.js would
  // append a real `step_status: complete` event for a completion the session
  // just reopened — an append-only stream can't take that back.
  if (masked.length > 0 && Array.isArray(resolutions)) {
    for (let i = resolutions.length - 1; i >= 0; i--) {
      const entry = resolutions[i];
      if (entry && masked.indexOf(entry.step) !== -1) resolutions.splice(i, 1);
    }
  }
}

module.exports = {
  FAILING_RUN_OUTCOMES,
  applyWriteCodeResume,
};
