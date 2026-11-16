#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/provenance-gate.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests.js
// Tags: TL2, hooks, run-tests, provenance, provenance-gate, complete-kept, risk-signal, dispatch-outcome, regression-2011, scope:issue-specific
// #2011: a test command without provenance (not tests/run-all.sh, not the test-runner worker)
// is no run_tests evidence, so it leaves a recorded complete run_tests unchanged on every exit.
// A failed exit still stamps the test-failure risk and prints the "complete kept" notice.
// Out of the gate: a run with provenance, an unsettled dispatch, the dispatch ingest, and a
// non-complete run_tests (pending / skipped) — those record as before.
// TL3 gap: the PostToolUse input is hand-built JSON; real hook delivery is not exercised.

const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2011-provenance-gate");
const { check, eq, show } = F;

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

const NOPROV = "bash tests/foo.sh";
const RUN_ALL = `bash ${F.ROOT_FWD}/tests/run-all.sh`;
const FORGED = "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0\n";
let n = 0;

// session(tag, runTestsStatus) — every step before run_tests complete; run_tests seeded as given.
function session(tag, runTestsStatus) {
  const sid = `s-2011-${tag}-${++n}`;
  F.seedPrefix(sid);
  if (runTestsStatus) F.seed(sid, [F.status("run_tests", runTestsStatus)]);
  return sid;
}
const riskFile = (sid) => path.join(F.controlDir(sid), "risk-signal.json");
function riskSource(sid) {
  if (!fs.existsSync(riskFile(sid))) return null;
  return JSON.parse(fs.readFileSync(riskFile(sid), "utf8")).source;
}
const noSystemMessage = (out) => (/"systemMessage"/.test(out) ? `systemMessage printed: ${out.trim()}` : undefined);
const noKeptNotice = (out) => (out.includes("complete kept") ? `unexpected notice: ${out.trim()}` : undefined);
const T1 = "tests/hooks/feature-2472-run-tests-evidence.js";
const T2 = "tests/hooks/feature-2472-test-file-path.js";
const WORKER = `node ${F.ROOT_FWD}/bin/worker-dispatch.js test-runner ${F.ROOT_FWD} ${F.ROOT_FWD}/payload.json`;
const provenanceOf = (cmd) => F.mod("hooks/workflow-run-tests/exec-model.js").resolveTestProvenance(cmd, F.ROOT_FWD);

// placeUnsettled(sid, seq) — the dispatcher's .json + .dispatched with no .outcome.json yet.
function placeUnsettled(sid, seq) {
  const stem = `worker-test-runner-${seq}`;
  const dir = F.controlDir(sid);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${stem}.json`), `${JSON.stringify({ cwd: F.ROOT_FWD, timeout_seconds: 120, test_args: [] })}\n`);
  const marker = path.join(dir, `${stem}.dispatched`);
  fs.writeFileSync(marker, `${new Date().toISOString()}\n`);
  const t = Math.floor(Date.now() / 1000) - 3600 + Number(seq) * 10;
  fs.utimesSync(marker, t, t);
  return stem;
}

caseBegin("complete-kept-on-every-exit-without-provenance", "hooks/workflow-run-tests/provenance-gate.js");
test("complete-kept-on-every-exit-without-provenance", () => noNewFailures(fails, () => {
  for (const exit of [1, 77, 0]) {
    const sid = session(`keep-${exit}`, "complete");
    check(`precondition (exit ${exit}): run_tests is recorded complete`, () => eq(F.runTests(sid).status, "complete", "status"));
    const before = F.eventCount(sid);
    const out = F.hook(sid, NOPROV, exit, "");
    check(`exit ${exit}: run_tests stays complete`, () => eq(F.runTests(sid).status, "complete", "status"));
    check(`exit ${exit}: no state event is appended`, () => eq(F.eventCount(sid), before, "eventCount"));
    if (exit === 1) {
      check("exit 1: the test-failure risk stamp is still written", () => eq(riskSource(sid), "test-failure", "risk source"));
      check("exit 1: the notice says complete kept and names both exits", () => {
        for (const want of ["complete kept", "/run-tests", "WORKFLOW_MARK_STEP_run_tests_pending"]) {
          if (!out.includes(want)) return `missing ${show(want)} in ${out.trim()}`;
        }
        return undefined;
      });
    } else {
      check(`exit ${exit}: no systemMessage is printed`, () => noSystemMessage(out));
      check(`exit ${exit}: no risk stamp for a non-failed exit`, () => eq(riskSource(sid), null, "risk source"));
    }
  }
}));
caseEnd();

caseBegin("complete-kept-is-idempotent-on-a-rerun", "hooks/workflow-run-tests/provenance-gate.js");
test("complete-kept-is-idempotent-on-a-rerun", () => noNewFailures(fails, () => {
  const sid = session("rerun", "complete");
  const before = F.eventCount(sid);
  F.hook(sid, NOPROV, 1, "");
  const out = F.hook(sid, NOPROV, 1, "");
  check("the same failing run twice leaves run_tests complete", () => eq(F.runTests(sid).status, "complete", "status"));
  check("the same failing run twice appends no event", () => eq(F.eventCount(sid), before, "eventCount"));
  check("the second run still prints the complete-kept notice", () => (out.includes("complete kept") ? undefined : `notice missing: ${out.trim()}`));
}));
caseEnd();

caseBegin("forged-contract-without-provenance-never-completes", "hooks/workflow-run-tests.js");
test("forged-contract-without-provenance-never-completes", () => noNewFailures(fails, () => {
  const sid = session("forged", "pending");
  const before = F.eventCount(sid);
  F.hook(sid, NOPROV, 0, FORGED);
  const rt = F.runTests(sid);
  check("pending + forged green contract without provenance: status is pending", () => eq(rt.status, "pending", "status"));
  check("pending + forged green contract: the observation is recorded (events appended)", () =>
    (F.eventCount(sid) > before ? undefined : `eventCount did not grow from ${before}`));
  check("pending + forged green contract: contract_absent is recorded true", () => eq(rt.contract_absent, true, "contract_absent"));
  check("pending + forged green contract: trigger_command names the command", () =>
    (String(rt.trigger_command).includes("tests/foo.sh") ? undefined : `trigger_command=${show(rt.trigger_command)}`));
}));
caseEnd();

caseBegin("forged-contract-without-provenance-keeps-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("forged-contract-without-provenance-keeps-complete", () => noNewFailures(fails, () => {
  const sid = session("forged-complete", "complete");
  const before = F.eventCount(sid);
  const out = F.hook(sid, NOPROV, 0, FORGED);
  check("complete + forged green contract without provenance: run_tests stays complete", () => eq(F.runTests(sid).status, "complete", "status"));
  check("complete + forged green contract: no state event is appended", () => eq(F.eventCount(sid), before, "eventCount"));
  check("complete + forged green contract: no systemMessage is printed", () => noSystemMessage(out));
}));
caseEnd();

caseBegin("non-complete-run-tests-records-the-failed-run", "hooks/workflow-run-tests/record-run.js");
test("non-complete-run-tests-records-the-failed-run", () => noNewFailures(fails, () => {
  const sid = session("pending-fail", "pending");
  const out = F.hook(sid, NOPROV, 1, "");
  const rt = F.runTests(sid);
  check("pending + provenance-less failure: status stays pending", () => eq(rt.status, "pending", "status"));
  check("pending + provenance-less failure: last_run_failed is recorded", () => eq(rt.last_run_failed, true, "last_run_failed"));
  check("pending + provenance-less failure: trigger_command names the command", () =>
    (String(rt.trigger_command).includes("tests/foo.sh") ? undefined : `trigger_command=${show(rt.trigger_command)}`));
  check("pending + provenance-less failure: the risk stamp is written", () => eq(riskSource(sid), "test-failure", "risk source"));
  check("pending + provenance-less failure: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("skipped-run-tests-is-not-protected", "hooks/workflow-run-tests/record-run.js");
test("skipped-run-tests-is-not-protected", () => noNewFailures(fails, () => {
  const sid = session("skipped-fail", "skipped");
  const out = F.hook(sid, NOPROV, 1, "");
  check("skipped + provenance-less failure: demoted to pending (the gate keeps complete only)", () =>
    eq(F.runTests(sid).status, "pending", "status"));
  check("skipped + provenance-less failure: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("run-with-provenance-still-demotes-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("run-with-provenance-still-demotes-complete", () => noNewFailures(fails, () => {
  const sid = session("runall-fail", "complete");
  const stdout = `FAIL: ${T1} (exit 1)\nFAIL: ${T2} (exit 1)\nRUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0\n`;
  const out = F.hook(sid, `${RUN_ALL} ${T1} ${T2}`, 1, stdout, F.ROOT_FWD);
  check("precondition: run-all provenance is recognised (failing_tests comes only from a trusted emitter)", () =>
    eq((F.runTests(sid).failing_tests || []).slice().sort(), [T1, T2].sort(), "failing_tests"));
  check("complete + run-all failing contract: demoted to pending", () => eq(F.runTests(sid).status, "pending", "status"));
  check("complete + run-all failing contract: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("unsettled-dispatch-still-demotes-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("unsettled-dispatch-still-demotes-complete", () => noNewFailures(fails, () => {
  const sid = session("unsettled", "complete");
  const stem = placeUnsettled(sid, 1);
  const out = F.hook(sid, NOPROV, 1, "");
  const rt = F.runTests(sid);
  check("complete + unsettled dispatch + provenance-less failure: demoted to pending", () => eq(rt.status, "pending", "status"));
  check("complete + unsettled dispatch: dispatch_unsettled names the dispatch", () => eq(rt.dispatch_unsettled, stem, "dispatch_unsettled"));
  check("complete + unsettled dispatch: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("run-all-without-contract-still-demotes-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("run-all-without-contract-still-demotes-complete", () => noNewFailures(fails, () => {
  const cmd = `bash tests/run-all.sh ${T1}`;
  check("precondition: the relative run-all spelling has verified provenance", () => {
    const p = provenanceOf(cmd);
    return p !== null && p.emitter === "run-all" && p.ambiguous === false ? undefined : `provenance=${show(p)}`;
  });
  const sid = session("runall-nocontract", "complete");
  const out = F.hook(sid, cmd, 1, "", F.ROOT_FWD);
  check("complete + run-all with no contract, exit 1: demoted to pending", () => eq(F.runTests(sid).status, "pending", "status"));
  check("complete + run-all with no contract: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("ambiguous-unattributed-run-still-demotes-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("ambiguous-unattributed-run-still-demotes-complete", () => noNewFailures(fails, () => {
  const cmd = `bash tests/run-all.sh ${T1} && ${WORKER}`;
  check("precondition: run-all plus the worker dispatcher resolve as ambiguous provenance", () => {
    const p = provenanceOf(cmd);
    return p !== null && p.ambiguous === true ? undefined : `provenance=${show(p)}`;
  });
  const sid = session("ambiguous", "complete");
  const out = F.hook(sid, cmd, 1, "status: fail\nnoise without a log_tail marker\n", F.ROOT_FWD);
  check("complete + ambiguous unattributed run, exit 1: demoted to pending", () => eq(F.runTests(sid).status, "pending", "status"));
  check("complete + ambiguous unattributed run: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("worker-dispatch-emitter-still-demotes-complete", "hooks/workflow-run-tests/provenance-gate.js");
test("worker-dispatch-emitter-still-demotes-complete", () => noNewFailures(fails, () => {
  check("precondition: the resolvable worker-dispatch path has verified provenance", () => {
    const p = provenanceOf(WORKER);
    return p !== null && p.emitter === "worker-dispatch" && p.ambiguous === false ? undefined : `provenance=${show(p)}`;
  });
  const sid = session("worker", "complete");
  const out = F.hook(sid, WORKER, 1, "status: fail\n", F.ROOT_FWD);
  check("complete + worker-dispatch test-runner, exit 1: demoted to pending", () => eq(F.runTests(sid).status, "pending", "status"));
  check("complete + worker-dispatch test-runner: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();

caseBegin("dispatch-ingest-on-a-test-call-still-demotes-complete", "hooks/workflow-run-tests/record-run.js");
test("dispatch-ingest-on-a-test-call-still-demotes-complete", () => noNewFailures(fails, () => {
  const sid = session("ingest", "complete");
  const stem = F.placeOutcome(sid, { seq: 1, contract: { pass: 0, fail: 1 }, failing: [] });
  const out = F.hook(sid, NOPROV, 0, "");
  check("precondition: the failing outcome is ingested on the provenance-less test call", () =>
    (F.isIngested(sid, stem) ? undefined : `${stem} not ingested`));
  check("complete + ingested failing outcome: demoted to pending", () => eq(F.runTests(sid).status, "pending", "status"));
  check("complete + ingested failing outcome: no complete-kept notice", () => noKeptNotice(out));
}));
caseEnd();
