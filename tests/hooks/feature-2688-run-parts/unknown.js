"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, fail-closed, scope:issue-specific
// T7: a selection the run's own evidence cannot prove is "unknown" — kept in run_parts and in
// the merge window, its failures kept, the merge held open (#3063). Causes: a contract whose
// count disagrees with the selection, an option run-all's parser does not prove (-j / --jobs /
// --all do), a directory argument, and on the stdout route a path with no result line.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("./drive");
const { check, eq } = F;
const { A, B, C } = D;

const lastSelection = (sid) => {
  const s = D.selections(sid);
  return s === null || s.length === 0 ? null : s[s.length - 1];
};

function countMismatchIsUnknown() {
  const cwd = D.repo();
  const sid = D.session("count");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  D.dispatch(sid, cwd, 2, [B], { pass: 1, fail: 2 }, [B, C]);
  check("T7: a [b] dispatch carrying a 3-test contract is unknown", () => {
    eq(lastSelection(sid), "unknown", "selection");
  });
  check("T7: the unknown run is recorded alone (failing [b, c])", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [B, C], "failing_tests");
  });
}

function flagOrDirectoryArgumentIsUnknown() {
  const cwd = D.repo();
  const sid = D.session("flag");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  D.dispatch(sid, cwd, 2, ["--auto"], { pass: 3 });
  check("T7: an option run-all does not know (--auto) is unknown and kept in run_parts", () => {
    eq(lastSelection(sid), "unknown", "selection");
    eq(D.selections(sid).length, 2, "run_parts length");
  });
  D.dispatch(sid, cwd, 3, [B], { pass: 1 });
  check("T7: the unknown element stays in the merge window and holds it open (failing [c] from the full run)", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [C], "failing_tests");
  });

  // -j / --jobs only set parallelism and --all runs the full suite: none of them is unknown.
  const jobs = D.session("jobs");
  D.dispatch(jobs, cwd, 1, ["-j", "2"], { pass: 3 });
  check("T7: a -j N dispatch is the full selection", () => eq(lastSelection(jobs), "full", "selection"));
  D.dispatch(jobs, cwd, 2, ["--jobs", "2", B], { pass: 1 });
  check("T7: a --jobs N <path> dispatch proves the path selection", () => eq(lastSelection(jobs), [B], "selection"));
  const all = D.session("all");
  D.dispatch(all, cwd, 1, ["--all", B], { pass: 3 });
  check("T7: an --all dispatch is the full selection whatever paths follow", () => eq(lastSelection(all), "full", "selection"));

  const dir = D.session("dir");
  D.dispatch(dir, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  D.dispatch(dir, cwd, 2, ["tests/hooks"], { pass: 3 });
  check("T7: a directory argument is unknown", () => {
    eq(lastSelection(dir), "unknown", "selection");
  });
}

// The stdout route: the real run-all of this checkout, the selection from the trigger command.
function stdoutRoute(tag, lines, contract) {
  const sid = D.session(tag);
  const T1 = "tests/hooks/feature-2472-run-tests-evidence.js";
  const T2 = "tests/hooks/feature-2472-test-file-path.js";
  const stdout = `${lines(T1, T2).join("\n")}\n${contract}\n`;
  F.hook(sid, `bash ${F.ROOT_FWD}/tests/run-all.sh ${T1} ${T2}`, 0, stdout, F.ROOT_FWD);
  return { sid, T1, T2 };
}

function stdoutPathWithoutLineIsUnknown() {
  const OK = "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0";
  const both = stdoutRoute("stdout-both", (a, b) => [`PASS: ${a}`, `PASS: ${b}`], OK);
  check("T7: stdout route precondition — the hook trusts this run-all and records the green run", () => {
    eq(F.runTests(both.sid).status, "complete", "status");
  });
  check("T7: stdout route — both selected paths have a PASS line, so the selection is the list", () => {
    eq(lastSelection(both.sid), [both.T1, both.T2].sort(), "selection");
  });
  const one = stdoutRoute("stdout-one", (a) => [`PASS: ${a}`], OK);
  check("T7: stdout route — a selected path with no result line makes the selection unknown", () => {
    eq(lastSelection(one.sid), "unknown", "selection");
  });
}

// The count agrees (EXECUTED+UNRUNNABLE = 1 = |[b]|) but the failing test is outside the selection.
// The unknown run clears nothing: the full run's [a, b] stay and its own [c] is added (#3063).
function failingOutsideSelectionIsUnknown() {
  const cwd = D.repo();
  const sid = D.session("subset");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [A, B]);
  D.dispatch(sid, cwd, 2, [B], { fail: 1 }, [C]);
  check("T7: a [b] dispatch whose count matches but whose failing [c] is outside [b] is unknown", () => {
    eq(lastSelection(sid), "unknown", "selection");
    eq(D.selections(sid).length, 2, "run_parts length");
  });
  check("T7: the subset-violating run clears nothing and adds its own failure (failing [a, b, c])", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [A, B, C], "failing_tests");
  });
}

module.exports = { countMismatchIsUnknown, flagOrDirectoryArgumentIsUnknown, stdoutPathWithoutLineIsUnknown, failingOutsideSelectionIsUnknown };
