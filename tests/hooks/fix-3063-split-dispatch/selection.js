"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, fail-closed, scope:issue-specific
// T-D3a-g, T-D3i: run-all options are read like tests/run-all.sh reads them (-j / --jobs and
// --all keep a run full or proven); an unknown part stays in the merge window, keeps its
// failures and holds run_tests open; a merge that throws fails closed.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("../feature-2688-run-parts/drive");
const K = require("./kit");
const { check, eq } = F;
const { A, B } = D;

const OPEN = "(run-parts-open)";
const lastSelection = (sid) => {
  const s = D.selections(sid);
  return s === null || s.length === 0 ? null : s[s.length - 1];
};

// One dispatch, ingested by a non-test hook call; returns the hook stdout.
function dispatchOut(sid, cwd, seq, testArgs, contract, failing, opts) {
  const stem = F.placeOutcome(sid, { seq, cwd, testArgs, contract, failing: failing || [] });
  const r = K.poke(sid, opts);
  if (!F.isIngested(sid, stem)) throw new Error(`fixture: ${stem} was not ingested`);
  return r;
}

const notComplete = (sid) => () => {
  const s = F.runTests(sid).status;
  return s !== "complete" ? null : "run_tests is complete";
};
const hasOpen = (out) => () => (out.includes(OPEN) ? null : `stdout lacks ${OPEN}: ${out}`);
const failingHas = (sid, p) => () => {
  const f = D.failing(sid);
  return Array.isArray(f) && f.includes(p) ? null : `failing_tests=${F.show(f)}`;
};

function unknownFailureSurvivesProvenRerun() {
  const cwd = D.repo();
  const sid = K.session("d3a");
  dispatchOut(sid, cwd, 1, ["tests/hooks"], { pass: 2, fail: 1 }, [A]);
  const r = dispatchOut(sid, cwd, 2, [A, B], { pass: 2 });
  check("T-D3a: the unknown part's failure survives a proven rerun of the same path", failingHas(sid, A));
  check("T-D3a: run_tests is not complete", notComplete(sid));
  check("T-D3a: the hook reports run-parts-open", hasOpen(r.stdout));
}

function unknownPassKeepsFullFailure() {
  const cwd = D.repo();
  const sid = K.session("d3b");
  dispatchOut(sid, cwd, 1, [], { pass: 2, fail: 1 }, [A]);
  const r = dispatchOut(sid, cwd, 2, ["tests/hooks"], { pass: 3 });
  check("T-D3b: the full run's failure survives an unknown green part", failingHas(sid, A));
  check("T-D3b: run_tests is not complete", notComplete(sid));
  check("T-D3b: the hook reports run-parts-open", hasOpen(r.stdout));
}

function fullRunAfterUnknownCompletes() {
  const cwd = D.repo();
  const sid = K.session("d3c");
  dispatchOut(sid, cwd, 1, [], { pass: 2, fail: 1 }, [A]);
  dispatchOut(sid, cwd, 2, ["tests/hooks"], { pass: 3 });
  dispatchOut(sid, cwd, 3, [], { pass: 3 });
  check("T-D3c: a full green run rebuilds run_parts to itself", () => eq(D.selections(sid), ["full"], "run_parts selections"));
  check("T-D3c: run_tests is complete", () => eq(F.runTests(sid).status, "complete", "status"));
}

function loneUnknownPassStaysOpen() {
  const cwd = D.repo();
  const sid = K.session("d3d");
  const r = dispatchOut(sid, cwd, 1, ["tests/hooks"], { pass: 3 });
  check("T-D3d: a lone unknown green part is recorded as unknown", () => eq(lastSelection(sid), "unknown", "selection"));
  check("T-D3d: run_tests is not complete", notComplete(sid));
  check("T-D3d: the hook reports run-parts-open", hasOpen(r.stdout));
}

function jobsOnlyRunIsFull() {
  const cwd = D.repo();
  const sid = K.session("d3e");
  dispatchOut(sid, cwd, 1, ["-j", "1"], { pass: 3 });
  check("T-D3e: a -j 1 run is the full selection", () => eq(lastSelection(sid), "full", "selection"));
  check("T-D3e: run_tests is complete", () => eq(F.runTests(sid).status, "complete", "status"));
}

function jobsWithPathIsProven() {
  const cwd = D.repo();
  const sid = K.session("d3f");
  dispatchOut(sid, cwd, 1, [], { pass: 2, fail: 1 }, [A]);
  dispatchOut(sid, cwd, 2, ["-j", "1", A], { pass: 1 });
  check("T-D3f: a -j 1 <path> run proves the path selection", () => eq(lastSelection(sid), [A], "selection"));
  check("T-D3f: the merge clears the rerun path", () => eq(D.failing(sid) || [], [], "failing_tests"));
  check("T-D3f: run_tests is complete", () => eq(F.runTests(sid).status, "complete", "status"));
}

const UNPROVABLE = [["--deadline", "60"], ["--print-plan"], ["-j"], ["--bogus"], ["--all", "--deadline", "60"], ["--all", "--print-plan"]];

function unprovableOptionsAreUnknown() {
  const cwd = D.repo();
  for (const args of UNPROVABLE) {
    const sid = K.session("d3g");
    const r = dispatchOut(sid, cwd, 1, args, { pass: 3 });
    const what = JSON.stringify(args);
    check(`T-D3g: ${what} is unknown`, () => eq(lastSelection(sid), "unknown", "selection"));
    check(`T-D3g: ${what} green run does not complete run_tests`, notComplete(sid));
    check(`T-D3g: ${what} reports run-parts-open`, hasOpen(r.stdout));
  }
}

// selectionFromArgs unit rows: both verdicts of the classifier, plus the parser's stop rules.
function optionTableRows() {
  const cwd = D.repo();
  const pick = K.runParts().selectionFromArgs;
  const rows = [
    [[], "full"], [[A, B], [A, B]], [["tests/hooks"], "unknown"],
    [["-j", "auto"], "full"], [["--jobs=4"], "full"], [["--all", A], "full"], [["--all", "-j", "2"], "full"],
    [["-j", "1", "--all"], "full"], [["-j", "2", "--jobs", "3", A], [A]], [["--", A], [A]],
    [[A, "-j", "1"], "unknown"], [["--", "-j"], "unknown"], [["--jobs"], "unknown"],
    [["--deadline=30"], "unknown"], [["--print-plan", "--all"], "unknown"],
  ];
  for (const [args, want] of rows) {
    check(`T-D3e: selectionFromArgs(${JSON.stringify(args)}) is ${JSON.stringify(want)}`, () => eq(pick(args, cwd), want, "selection"));
  }
}

function mergeExceptionFailsClosed() {
  const cwd = D.repo();
  const sid = K.session("d3i");
  dispatchOut(sid, cwd, 1, [], { pass: 2, fail: 1 }, [A]);
  const r = dispatchOut(sid, cwd, 2, [B], { pass: 1 }, [], { throwRecordParts: true });
  check("T-D3i: a throwing merge does not complete run_tests", notComplete(sid));
  check("T-D3i: the hook reports run-parts-open", hasOpen(r.stdout));
  check("T-D3i: the earlier failure stays on the rerun-list", () => {
    const out = K.rerunList(sid).stdout || "";
    return out.split("\n").includes(A) ? null : `rerun-list=${F.show(out)}`;
  });
  check("T-D3i: the merge failure is written to stderr", () => (r.stderr.includes("f3063-injected") ? null : `stderr=${F.show(r.stderr)}`));
}

module.exports = {
  unknownFailureSurvivesProvenRerun, unknownPassKeepsFullFailure, fullRunAfterUnknownCompletes,
  loneUnknownPassStaysOpen, jobsOnlyRunIsFull, jobsWithPathIsProven, unprovableOptionsAreUnknown,
  optionTableRows, mergeExceptionFailsClosed,
};
