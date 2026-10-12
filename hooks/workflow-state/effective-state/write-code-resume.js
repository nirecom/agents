"use strict";
// Stage 5 of reconcileEffectiveState: the write_code resume cascade. A FAILING
// run_tests outcome reopens (derived-only) every step settled before it, so the
// session goes back through /write-code before it can commit.
// `run_outcome` and the compared seqs come from the RAW projection (the derived
// entry stays minimal); only `status` comes from the derived side (stages 1-4).
// No provenance check is needed: this is a seq comparison, inherited/v1 completions
// always carry a smaller seq, and the v2→v3 backfill (state-io/migrations/v2-to-v3.js)
// can never coexist with a `run_outcome` of the same schema version.

// Outcomes that mean "the run reported a failure"; absent / null / "pass" are not.
// "unrunnable" is excluded: a missing runtime is not a code defect to resume write_code for.
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
