#!/bin/bash
# tests/feature-1665-seq-cascade/e-cascade.sh
# Tests: hooks/workflow-state/effective-state/write-code-resume.js, hooks/workflow-state/effective-state.js
# Tags: workflow-state, write-code-resume, cascade, updated-seq, derived-state, scope:issue-specific, pwsh-not-required, TL1
#
# E — the write-code resume cascade.
#
# WHY: when run_tests records a failing outcome, every step SETTLED BEFORE that
# failure is stale — the code it signed off on is about to change. The cascade
# reopens write_code and masks the downstream steps whose settlement predates the
# failing run (updated_seq <= run_tests.updated_seq), while steps settled AFTER
# the failure keep their status.
#
# The masking is DERIVED ONLY: it happens inside reconcileEffectiveState and is
# never written back to the event stream (see case h).
#
# E8 additionally pins the layering: the derived entry from
# reconcileEffectiveState exposes only {status, resolved_from} — no updated_seq —
# so the cascade must read its inputs from the RAW projection it is handed, not
# from the derived snapshot it is mutating.

CASE_TAG=e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# ------------------------------------------------------------------ unit cases
js_g '
const W = require(process.env.M_WCR);

// Raw projection stub + the derived snapshot the reconciler has built so far.
function scenario(runOutcome, opts) {
  opts = opts || {};
  const state = { steps: {
    write_tests:     { status: "complete", updated_seq: 2 },
    write_code:      { status: opts.writeCodeStatus || "complete", updated_seq: 5 },
    docs:            { status: "pending",  updated_seq: 4 },
    review_security: { status: "complete", updated_seq: 20 },
    run_tests:       { status: "pending",  updated_seq: 10 },
  }};
  if (runOutcome !== undefined) state.steps.run_tests.run_outcome = runOutcome;
  const steps = {
    write_tests:     { status: "complete", resolved_from: "state" },
    write_code:      { status: opts.writeCodeStatus || "complete", resolved_from: opts.writeCodeFrom || "state" },
    docs:            { status: "complete", resolved_from: "evidence" },
    review_security: { status: "complete", resolved_from: "state" },
    run_tests:       { status: "pending",  resolved_from: "state" },
  };
  const resolutions = [{ step: "docs", source: "evidence" }];
  W.applyWriteCodeResume(steps, resolutions, state);
  return { steps, resolutions };
}

const r1 = scenario("fail");
console.log("E1.write_code=" + r1.steps.write_code.status);
console.log("E1.write_code_from=" + r1.steps.write_code.resolved_from);
console.log("E1.docs=" + r1.steps.docs.status);
console.log("E1.docs_from=" + r1.steps.docs.resolved_from);
console.log("E1.review_security=" + r1.steps.review_security.status);
console.log("E1.run_tests=" + r1.steps.run_tests.status);
console.log("E1.write_tests=" + r1.steps.write_tests.status);
console.log("E1.resolutions=" + r1.resolutions.map((x) => x.step).join(",") + ".");

console.log("E2.absent=" + scenario(undefined).steps.write_code.status);
console.log("E3.pass=" + scenario("pass").steps.write_code.status);
console.log("E4.timeout=" + scenario("timeout").steps.write_code.status);
console.log("E5.runner_error=" + scenario("runner-error").steps.write_code.status);

// E6 — idempotent: an already-reopened write_code keeps its earlier provenance.
const r6 = scenario("fail", { writeCodeStatus: "pending", writeCodeFrom: "post-veto-reset" });
console.log("E6.status=" + r6.steps.write_code.status);
console.log("E6.from=" + r6.steps.write_code.resolved_from);

// E7 — a SKIPPED downstream step settled before the failure is masked too:
// "skipped" is a settlement decision about code that is now changing.
const state7 = { steps: {
  write_code: { status: "complete", updated_seq: 3 },
  docs:       { status: "skipped",  updated_seq: 4 },
  run_tests:  { status: "pending",  updated_seq: 10, run_outcome: "fail" },
}};
const steps7 = {
  write_code: { status: "complete", resolved_from: "state" },
  docs:       { status: "skipped",  resolved_from: "state" },
  run_tests:  { status: "pending",  resolved_from: "state" },
};
W.applyWriteCodeResume(steps7, [], state7);
console.log("E7.docs=" + steps7.docs.status);
'

if require_js_ok "E: cascade unit probe"; then
    assert_js "E1 write_code reopens on a failing run" E1.write_code "pending"
    assert_js "E1 reopen is attributed to the cascade" E1.write_code_from "write-code-resumed"
    assert_js "E1 downstream settled BEFORE the failure is masked" E1.docs "pending"
    assert_js "E1 masked step is re-attributed" E1.docs_from "write-code-resumed"
    assert_js "E1 downstream settled AFTER the failure is untouched" E1.review_security "complete"
    assert_js "E1 run_tests itself is untouched" E1.run_tests "pending"
    assert_js "E1 upstream of write_code is untouched" E1.write_tests "complete"
    assert_js "E1 masked step removed from resolutions" E1.resolutions "."
    assert_js "E2 no run_outcome: no cascade" E2.absent "complete"
    assert_js "E3 passing run: no cascade" E3.pass "complete"
    assert_js "E4 timeout outcome fires the cascade" E4.timeout "pending"
    assert_js "E5 runner-error outcome fires the cascade" E5.runner_error "pending"
    assert_js "E6 idempotent on an already-pending write_code" E6.status "pending"
    assert_js "E6 existing provenance is not overwritten" E6.from "post-veto-reset"
    assert_js "E7 a pre-failure skipped step is masked too" E7.docs "pending"
fi

# ----------------------------------------------------------- E8: integration
# Through the real reconcileEffectiveState on a real state file.
js_g '
const S = require(process.env.M_SIO);
const { reconcileEffectiveState } = require(process.env.M_ES);
const sid = "seq1665-e8";
const seq = [
  ["workflow_init", "complete"], ["clarify_intent", "complete"],
  ["research", "skipped"], ["outline", "skipped"], ["detail", "skipped"],
  ["branching_complete", "complete"], ["write_tests", "complete"],
  ["review_tests", "complete"], ["write_code", "complete"],
  ["review_security", "complete"],
];
for (const [step, status] of seq) S.markStep(sid, step, status);
S.markStep(sid, "run_tests", "pending", { run_outcome: "fail" });
S.markStep(sid, "docs", "complete");

const state = S.readState(sid);
const eff = reconcileEffectiveState(state, sid, { resolveAll: true });
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
console.log("E8.derived_keys=" + Object.keys(eff.steps.write_code).sort().join(","));
console.log("E8.has_updated_seq=" + has(eff.steps.write_code, "updated_seq"));
console.log("E8.write_code=" + eff.steps.write_code.status);
console.log("E8.write_code_from=" + eff.steps.write_code.resolved_from);
console.log("E8.review_security=" + eff.steps.review_security.status);
console.log("E8.docs=" + eff.steps.docs.status);
console.log("E8.run_tests=" + eff.steps.run_tests.status);
console.log("E8.raw_write_code=" + state.steps.write_code.status);
'

if require_js_ok "E8: reconcile integration probe"; then
    assert_js "E8 derived entry is still {status,resolved_from} only" E8.derived_keys "resolved_from,status"
    assert_js "E8 derived entry exposes no updated_seq" E8.has_updated_seq "false"
    assert_js "E8 cascade fires through reconcileEffectiveState" E8.write_code "pending"
    assert_js "E8 reopen attributed to the cascade" E8.write_code_from "write-code-resumed"
    assert_js "E8 pre-failure downstream masked" E8.review_security "pending"
    assert_js "E8 post-failure downstream survives" E8.docs "complete"
    assert_js "E8 run_tests unchanged" E8.run_tests "pending"
    assert_js "E8 raw stream is NOT rewritten (derived-only)" E8.raw_write_code "complete"
fi

finish
