"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, fail-closed, scope:issue-specific
// T7: a selection the run's own evidence cannot prove is "unknown" — recorded alone, kept in
// run_parts, never merged. Causes: a contract whose count disagrees with the selection (a
// second dispatch reporting the first one's contract), a flag or directory argument, and on
// the stdout route a selected path with no PASS/FAIL/SKIP/UNRUNNABLE line.

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
  check("T7: a --auto dispatch is unknown and kept in run_parts", () => {
    eq(lastSelection(sid), "unknown", "selection");
    eq(D.selections(sid).length, 2, "run_parts length");
  });
  D.dispatch(sid, cwd, 3, [B], { pass: 1 });
  check("T7: the unknown element is left out of the next merge (failing [c] from the full run)", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [C], "failing_tests");
  });

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
// Merged, the full run's [a] would survive; recorded alone, the run says only [c].
function failingOutsideSelectionIsUnknown() {
  const cwd = D.repo();
  const sid = D.session("subset");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [A, B]);
  D.dispatch(sid, cwd, 2, [B], { fail: 1 }, [C]);
  check("T7: a [b] dispatch whose count matches but whose failing [c] is outside [b] is unknown", () => {
    eq(lastSelection(sid), "unknown", "selection");
    eq(D.selections(sid).length, 2, "run_parts length");
  });
  check("T7: the subset-violating run is recorded alone, not merged (failing [c], not [a, ...])", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [C], "failing_tests");
  });
}

module.exports = { countMismatchIsUnknown, flagOrDirectoryArgumentIsUnknown, stdoutPathWithoutLineIsUnknown, failingOutsideSelectionIsUnknown };
