#!/bin/bash
# tests/feature-1665-seq-cascade/f-inherited-null-seq.sh
# Tests: hooks/workflow-state/effective-state/write-code-resume.js, hooks/workflow-state/inheritance/apply.js
# Tags: workflow-state, write-code-resume, inheritance, null-seq, fail-safe, scope:issue-specific, pwsh-not-required, TL1
#
# F — the null-seq rule.
#
# WHY: session inheritance carries a donor's step STATUSES forward but the heir's
# stream is brand new, so a step the donor never re-settled can arrive with a
# `run_outcome` annotation and no step_status event at all — leaving
# run_tests.updated_seq null. "Unknown when the failure happened" must not be
# read as "the failure happened at position 0", which would mask nothing at all
# and let a stale write_code sign-off survive into the heir session.
#
# Rule: resumeSeq = Number.isFinite(run_tests.updated_seq) ? value : Infinity.
# The Infinity branch is fail-SAFE — it masks EVERY downstream step, including
# those whose own updated_seq is non-numeric. The finite branch is deliberately
# NOT symmetric: with a real baseline in hand, a downstream step whose position is
# unknown cannot be proven stale, so it is left alone.

CASE_TAG=f
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# ---------------------------------------------------- F1/F2: real inheritance
js_g '
const S = require(process.env.M_SIO);
const A = require(process.env.M_INH);
const { reconcileEffectiveState } = require(process.env.M_ES);

function inherit(tag, outcome) {
  const donor = "seq1665-f" + tag + "d";
  const heir = "seq1665-f" + tag + "h";
  for (const [s, st] of [
    ["workflow_init", "complete"], ["clarify_intent", "complete"],
    ["research", "skipped"], ["outline", "skipped"], ["detail", "skipped"],
    ["branching_complete", "complete"], ["write_tests", "complete"],
    ["review_tests", "complete"], ["write_code", "complete"],
  ]) S.markStep(donor, s, st);
  S.markStep(donor, "run_tests", "pending", { run_outcome: outcome });
  A.applyInheritance(heir, "2026-02-01T00:00:00.000Z", S.readState(donor));
  const st = S.readState(heir);
  return { heir, st, eff: reconcileEffectiveState(st, heir, { resolveAll: true }) };
}

const f1 = inherit("1", "fail");
console.log("F1.run_tests_seq=" + JSON.stringify(f1.st.steps.run_tests.updated_seq));
console.log("F1.run_outcome=" + JSON.stringify(f1.st.steps.run_tests.run_outcome));
console.log("F1.write_code_raw=" + f1.st.steps.write_code.status);
console.log("F1.write_code_seq_is_number=" + (typeof f1.st.steps.write_code.updated_seq === "number"));
console.log("F1.eff_write_code=" + f1.eff.steps.write_code.status);
console.log("F1.eff_from=" + f1.eff.steps.write_code.resolved_from);

const f2 = inherit("2", "pass");
console.log("F2.eff_write_code=" + f2.eff.steps.write_code.status);
'

if require_js_ok "F: inheritance probe"; then
    assert_js "F1 inherited run_tests carries no seq (fixture precondition)" F1.run_tests_seq "null"
    assert_js "F1 inherited run_outcome survives" F1.run_outcome '"fail"'
    assert_js "F1 raw write_code is complete (fixture precondition)" F1.write_code_raw "complete"
    assert_js "F1 inherited write_code does have a seq" F1.write_code_seq_is_number "true"
    assert_js "F1 null baseline still reopens write_code (fail-safe)" F1.eff_write_code "pending"
    assert_js "F1 reopen attributed to the cascade" F1.eff_from "write-code-resumed"
    assert_js "F2 passing outcome does not fire on the null path (CPR-ORTH)" F2.eff_write_code "complete"
fi

# ------------------------------------------------- F3/F4: the asymmetry itself
js_g '
const W = require(process.env.M_WCR);

function run(baselineSeq, withOutcome) {
  const state = { steps: {
    write_code:  { status: "complete", updated_seq: 3 },
    docs:        { status: "complete", updated_seq: null },
    review_security: { status: "complete", updated_seq: "9" },
    cleanup:     { status: "complete", updated_seq: 4 },
    user_verification: { status: "complete", updated_seq: 99 },
    run_tests:   { status: "pending", updated_seq: baselineSeq },
  }};
  if (withOutcome) state.steps.run_tests.run_outcome = "fail";
  const steps = {};
  for (const k of Object.keys(state.steps)) {
    steps[k] = { status: state.steps[k].status, resolved_from: "state" };
  }
  W.applyWriteCodeResume(steps, [], state);
  return steps;
}

const f3 = run(10, true);
console.log("F3.write_code=" + f3.write_code.status);
console.log("F3.null_seq=" + f3.docs.status);
console.log("F3.string_seq=" + f3.review_security.status);
console.log("F3.numeric_below=" + f3.cleanup.status);
console.log("F3.numeric_above=" + f3.user_verification.status);

const f4 = run(null, true);
console.log("F4.write_code=" + f4.write_code.status);
console.log("F4.null_seq=" + f4.docs.status);
console.log("F4.string_seq=" + f4.review_security.status);
console.log("F4.numeric_above=" + f4.user_verification.status);
'

if require_js_ok "F: asymmetry probe"; then
    assert_js "F3 finite baseline reopens write_code" F3.write_code "pending"
    assert_js "F3 finite baseline does NOT mask a null-seq downstream" F3.null_seq "complete"
    assert_js "F3 finite baseline does NOT mask a non-numeric seq" F3.string_seq "complete"
    assert_js "F3 finite baseline masks a lower numeric seq (non-vacuity)" F3.numeric_below "pending"
    assert_js "F3 finite baseline spares a higher numeric seq" F3.numeric_above "complete"
    assert_js "F4 null baseline reopens write_code" F4.write_code "pending"
    assert_js "F4 null baseline masks a null-seq downstream (fail-safe)" F4.null_seq "pending"
    assert_js "F4 null baseline masks a non-numeric seq (fail-safe)" F4.string_seq "pending"
    assert_js "F4 null baseline masks even the highest seq" F4.numeric_above "pending"
fi

finish
