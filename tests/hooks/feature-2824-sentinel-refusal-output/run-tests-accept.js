"use strict";
// run-tests-accept-handler refusals (#2824 Step 2): short reason, no recorded run, malformed -> UNAPPLIED.

const A = (body) => `echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED${body}>>"`;

function refusals(X) {
  const sid = X.seedInit("rta");
  X.expectUnapplied("reason too short", sid, A(": ab"), /too short/i);
  X.expectUnapplied("no recorded run", sid, A(": Pester 5 cannot be installed on this host"), /rejected/i);
  X.expectUnapplied("malformed (paren)", sid, A(": Pester 5 (CI only)"), /malformed|must not contain/i);
  X.expectUnapplied("bare", sid, A(""), /malformed|must not contain/i);
  // The catch path: a state file that is not JSON makes appendEvents throw.
  X.expectUnapplied("state write fails", X.corruptState("rta-corrupt"), A(": Pester 5 cannot be installed on this host"),
    /failed to write state[\s\S]*NOT recorded/);
  X.check();
}

// seedUnrunnable(X, tag) -> sid whose run_tests is pending on contract-unrunnable (2 tests, pwsh missing).
function seedUnrunnable(X, tag) {
  const sid = X.seedInit(tag);
  X.F.S.markStep(sid, "run_tests", "pending", { run_outcome: "unrunnable", unrunnable_count: 2, unrunnable_runtimes: "pwsh" });
  return sid;
}

function applied(X) {
  const sid = seedUnrunnable(X, "rta-ok");
  X.expectInfo("accepted", sid, A(": Pester 5 cannot be installed on this host"), /RUN_TESTS_UNRUNNABLE_ACCEPTED: run_tests complete with 2/);
  const st = ((X.F.S.readState(sid) || {}).steps || {}).run_tests || {};
  if (st.status !== "complete") X.record("accepted", `run_tests is ${st.status}, expected complete`);
  X.check();
}

// #2473: the runner-error the worker returns for a repo with no usable tests section (/migrate) is
// not an unrunnable-runtime run, so the accept sentinel must not complete run_tests over it.
function uninitializedRunnerError(X) {
  const sid = X.seedInit("rta-uninit");
  X.F.S.markStep(sid, "run_tests", "pending", { run_outcome: "runner-error" });
  X.expectUnapplied("uninitialized runner-error", sid, A(": the repo has no tests section yet"),
    /not pending on contract-unrunnable \(run_outcome=runner-error\)/);
  const st = ((X.F.S.readState(sid) || {}).steps || {}).run_tests || {};
  if (st.status !== "pending") X.record("uninitialized runner-error", `run_tests is ${st.status}, expected pending`);
  X.check();
}

module.exports = { refusals, applied, seedUnrunnable, uninitializedRunnerError };
