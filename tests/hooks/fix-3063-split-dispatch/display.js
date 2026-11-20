"use strict";
// Tests: skills/run-tests/scripts/show-dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, fail-closed, scope:issue-specific
// T-D6: one dispatch shows and records as before. Several unconsumed stems show one block each,
// in dispatch order. T-D7: a control dir that exists but cannot be scanned (EACCES) is never
// "no dispatch": it demotes, blocks a green run, stops the baseline, shows OUTCOME=scan-failed.

const fs = require("fs");
const F = require("../../lib/run-tests-outcome-fixture");
const D = require("../feature-2688-run-parts/drive");
const K = require("./kit");
const { check, eq } = F;
const { A, B } = D;

const block = (stem, state, reason) => `DISPATCH_STEM=${stem}\nOUTCOME=${state}\nOUTCOME_REASON=${reason}\n---\n`;
const startsWith = (out, head) => () => (out.startsWith(head) ? null : `stdout=${F.show(out)}`);

function singleDispatchDisplayUnchanged() {
  const cwd = D.repo();
  const sid = K.session("one");
  const stem = K.place(sid, { seq: 1, cwd, testArgs: [A], contract: { pass: 1 } });
  const before = K.show(sid);
  check("T-D6: one trusted dispatch shows the present header first", startsWith(before.stdout, block(stem, "present", "-")));
  check("T-D6: one dispatch shows exactly one block", () => eq(K.stemsShown(before.stdout), [stem], "stems shown"));
  K.poke(sid);
  check("T-D6: the single dispatch records run_tests complete", () => eq(F.runTests(sid).status, "complete", "status"));
  const after = K.show(sid);
  check("T-D6: after ingest the latest dispatch is still shown, unchanged", () => eq(after.stdout, before.stdout, "show output"));

  const abs = K.session("one-absent");
  const absStem = K.place(abs, { seq: 1, cwd, testArgs: [A], absent: true });
  check("T-D6: an absent outcome shows the absent header only", () => eq(K.show(abs).stdout, block(absStem, "absent", "absent"), "show output"));
  const none = K.session("one-none");
  const r = K.show(none);
  check("T-D6: no dispatch shows the none header", () => eq([r.status, r.stdout], [0, block("none", "absent", "no-dispatch")], "exit, show output"));
}

function unconsumedStemsShownInOrder() {
  const cwd = D.repo();
  const sid = K.session("two-show");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], contract: { fail: 1 }, failing: [A] });
  const b = K.place(sid, { seq: 2, cwd, testArgs: [B], contract: { pass: 1 } });
  const out = K.show(sid).stdout;
  check("T-D1: show prints one block per unconsumed stem, in dispatch order", () => eq(K.stemsShown(out), [a, b], "stems shown"));
  check("T-D1: each block is a present outcome", () => {
    eq(out.split("\n").filter((l) => l === "OUTCOME=present").length, 2, "OUTCOME=present lines");
  });
}

function untrustedStemShownAsBlock() {
  const cwd = D.repo();
  const sid = K.session("untrusted-show");
  const stem = K.place(sid, { seq: 1, cwd, testArgs: [A], contract: { pass: 1 }, untrusted: true });
  const lines = K.headerLines(K.show(sid).stdout);
  check("untrusted show: the stem is shown with OUTCOME=untrusted", () => {
    eq(lines.slice(0, 2), [`DISPATCH_STEM=${stem}`, "OUTCOME=untrusted"], "header lines");
  });
  check("untrusted show: OUTCOME_REASON names the trust check that failed", () => eq(lines[2], "OUTCOME_REASON=session-mismatch", "reason line"));
}

// A session whose control dir exists; every child below gets EACCES on its scan.
function scanFailingSession(tag) {
  const sid = K.session(tag);
  fs.mkdirSync(F.controlDir(sid), { recursive: true });
  return sid;
}
const FAULT = (sid) => ({ eaccesSid: sid });

function scanFailureDemotesNonTestCall() {
  const sid = scanFailingSession("scan-a");
  K.seedComplete(sid);
  const r = K.poke(sid, FAULT(sid));
  check("T-D7a: a non-test call under a scan failure demotes run_tests", () => eq(F.runTests(sid).status, "pending", "status"));
  check("T-D7a: dispatch_unsettled is the scan-failed stem", () => eq(F.runTests(sid).dispatch_unsettled, K.SCAN_FAILED_STEM, "dispatch_unsettled"));
  check("T-D7a: the reason is dispatch-unsettled", () => (r.stdout.includes("(dispatch-unsettled)") ? null : `stdout=${F.show(r.stdout)}`));
  check("T-D7a: the message carries the scan reason", () => (r.stdout.includes("control dir scan failed") ? null : `stdout=${F.show(r.stdout)}`));
}

function greenStdoutRun(sid, opts) {
  const T1 = "tests/hooks/feature-2472-run-tests-evidence.js";
  const T2 = "tests/hooks/feature-2472-test-file-path.js";
  const stdout = `PASS: ${T1}\nPASS: ${T2}\nRUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0\n`;
  return K.hook(sid, `bash ${F.ROOT_FWD}/tests/run-all.sh ${T1} ${T2}`, 0, stdout, F.ROOT_FWD, opts);
}

function scanFailureBlocksGreenStdoutRun() {
  const control = scanFailingSession("scan-b-control");
  greenStdoutRun(control);
  check("T-D7b: precondition — the same green run completes without the fault", () => eq(F.runTests(control).status, "complete", "status"));
  const sid = scanFailingSession("scan-b");
  greenStdoutRun(sid, FAULT(sid));
  check("T-D7b: a green test run under a scan failure does not complete run_tests", () => {
    const s = F.runTests(sid).status;
    return s !== "complete" ? null : "run_tests is complete";
  });
  check("T-D7b: the green run records the scan-failed stem as unsettled", () => eq(F.runTests(sid).dispatch_unsettled, K.SCAN_FAILED_STEM, "dispatch_unsettled"));
}

function scanFailureStopsBaselinePrecondition() {
  const sid = scanFailingSession("scan-c");
  const got = K.precondition(sid, { outcome_source: null }, FAULT(sid));
  check("T-D7c: dispatchPrecondition returns the scan reason", () => {
    return typeof got === "string" && got.includes("control dir scan failed") ? null : `got ${F.show(got)}`;
  });
}

function scanFailureShownAsBlock() {
  const sid = scanFailingSession("scan-d");
  const r = K.show(sid, FAULT(sid));
  const lines = K.headerLines(r.stdout);
  check("T-D7d: show names the scan-failed stem and state", () => {
    eq(lines.slice(0, 2), [`DISPATCH_STEM=${K.SCAN_FAILED_STEM}`, "OUTCOME=scan-failed"], "header lines");
  });
  check("T-D7d: OUTCOME_REASON carries the scan reason", () => {
    const reason = lines[2] || "";
    return reason.startsWith("OUTCOME_REASON=") && reason.includes("control dir scan failed") ? null : `reason line=${F.show(reason)}`;
  });
}

// A missing control dir is "no dispatch yet", not a scan failure (the fault never fires).
function missingControlDirIsNoDispatch() {
  const sid = K.session("no-dir");
  K.seedComplete(sid);
  K.poke(sid, FAULT(sid));
  check("missing control dir: run_tests stays complete", () => eq(F.runTests(sid).status, "complete", "status"));
  check("missing control dir: show prints the none header", () => eq(K.show(sid, FAULT(sid)).stdout, block("none", "absent", "no-dispatch"), "show output"));
  check("missing control dir: dispatchPrecondition does not refuse", () => eq(K.precondition(sid, { outcome_source: null }, FAULT(sid)), null, "precondition"));
}

module.exports = {
  singleDispatchDisplayUnchanged, unconsumedStemsShownInOrder, untrustedStemShownAsBlock, scanFailureDemotesNonTestCall,
  scanFailureBlocksGreenStdoutRun, scanFailureStopsBaselinePrecondition, scanFailureShownAsBlock,
  missingControlDirIsNoDispatch,
};
