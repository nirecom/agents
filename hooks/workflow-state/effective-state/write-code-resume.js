"use strict";
// Stage 5 of reconcileEffectiveState: the write_code resume cascade (#1665).
//
// WHY: when `run_tests` records a FAILING outcome, every step that was settled
// BEFORE that failure signed off on code which is about to change. Those
// settlements are stale. The cascade reopens them (derived-only) so the session
// goes back through /write-code before it can commit.
//
// Split out of effective-state.js (already over the 300-line WARN) per
// rules/coding/file-split.md pattern A.
//
// WHERE EACH INPUT COMES FROM (R1 — getting this wrong makes the feature a
// permanent no-op):
//   trigger `run_outcome`   ← state.steps.run_tests.run_outcome  (RAW projection)
//   baseline `resumeSeq`    ← state.steps.run_tests.updated_seq  (RAW projection)
//   compared `updated_seq`  ← state.steps[step].updated_seq      (RAW projection)
//   masked `status`         ← steps[step].status                 (DERIVED)
//   writes                  → steps[step] and resolutions        (DERIVED only)
//
// The derived entry built by effective-state.js is deliberately minimal —
// `{ status, resolved_from, [skip_verdict_state] }` — and MUST NOT be widened to
// carry `updated_seq`: it is a raw recorded fact, not a derived judgement, and
// re-stating it in the derived view would create a second owner (CPR-SSOT) plus
// a "forgot to carry it on rebuild" trap in every stage that rewrites an entry.
// Stage 5 therefore reads the raw projection it is handed. Only `status` comes
// from the derived side, so stages 1-4 are respected.
//
// RELATIONSHIP TO `provenance:"backfilled"` / hasGenuineRecordedComplete
// (obligation 2 — do NOT add a provenance condition to this cascade):
//
// hasGenuineRecordedComplete (effective-state.js) scans the raw stream and
// requires the step's latest step_status to be `complete` with a non-backfilled
// provenance. Its sole consumer is evaluateResumability's S3, and its question
// is "may a continuing session reuse this state?".
//
// The cascade's question is different: "was this completion recorded BEFORE the
// failure we just observed?". The two axes are:
//   genuineness  — did THIS session observe the completion?  → inheritance
//   updated_seq  — is the completion older than the failure? → staleness
//
// They happen to agree on inherited work, which is exactly why a provenance
// condition here would be redundant AND harmful. inheritance/apply.js does not
// copy the donor's `steps`; it appends fresh events to the HEIR's own stream, so
// inherited completions sit near the head and always carry a smaller
// `updated_seq` — they are masked automatically. Adding `provenance` would
// introduce a second, independently-drifting decision axis for the same outcome.
// The one case where the seq axis has nothing to say — an inherited `run_tests`
// that stayed pending, so no step_status event and no `updated_seq` — is handled
// by the Infinity rule below, not by provenance.
//
// v1-migration-derived completions need no special case either: `write_code`
// does not exist in v1, so any v1-derived downstream completion necessarily
// carries a smaller seq than the current resume point. The inversion is
// structurally impossible.
//
// The v2→v3 backfill (state-io/migrations/v2-to-v3.js) is the one place that
// CAN put a `write_code: complete` at the TAIL of a stream — a seq LARGER than
// run_tests' — which would read as "not stale" and escape the mask. It needs no
// handling here, for a reason that must hold as an invariant rather than a
// coincidence: the cascade's trigger is the `run_outcome` annotation, which
// shipped in the same release as schema v3, so only code that already stamps
// v3 can write it. A file eligible for the backfill therefore cannot carry a
// `run_outcome` at all, and the cascade is inert at the moment of migration.
// Every LATER failure appends events after the backfilled record, restoring the
// normal ordering. If a future release ever backdates a backfilled completion's
// seq, or emits `run_outcome` on a pre-v3 file, re-examine this paragraph.

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
  // Lazy require: effective-state.js is itself reachable from state-io's own
  // dependents, and a load-time destructure would capture `undefined` whenever
  // this module is pulled in mid-cycle.
  const { VALID_STEPS } = require("../state-io");
  const rawSteps = (state && state.steps) || {};
  const runTests = rawSteps.run_tests || {};

  // 1. Trigger — the recorded outcome of run_tests, and nothing else.
  if (FAILING_RUN_OUTCOMES.indexOf(runTests.run_outcome) === -1) return;

  // 2. Baseline. A non-finite position means "we cannot prove WHEN the failure
  //    happened", so the exception ("completions after the failure survive")
  //    cannot be applied and we fall back to the rule: everything downstream is
  //    stale. Infinity is that fallback, not an arbitrary default (C3,
  //    fail-SAFE — an extra test run costs far less than committing on a
  //    completion that was never re-verified).
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

    // 3. Comparison is explicitly numeric — no coercion. With a FINITE baseline
    //    a non-numeric position is left alone: an unknown position cannot be
    //    proven to predate a known failure. With an INFINITE baseline nothing is
    //    known about ordering at all, so every settled downstream step is masked.
    const stepSeq = (rawSteps[step] || {}).updated_seq;
    const stale = Number.isFinite(stepSeq) ? stepSeq < resumeSeq : resumeSeq === Infinity;
    if (!stale) continue;

    derived.status = "pending";
    derived.resolved_from = RESOLVED_FROM;
    masked.push(step);
  }

  // 4. A masked step must not survive in `resolutions`: verdict.js's
  //    persistResolutions() would append a real `step_status: complete` event
  //    for it, durably recording a completion the session just reopened. An
  //    append-only stream cannot take that back.
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
