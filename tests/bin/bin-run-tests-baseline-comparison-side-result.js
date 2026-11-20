#!/usr/bin/env node
"use strict";
// Tests: bin/lib/run-tests-baseline-comparison-side-result.js
// Tags: TL1, bin, run-tests-baseline, comparison-side-result, table-driven, scope:common
// #3068 — parseComparisonSideResult(execOutputs, errHitLines) builds the comparison side result
// {verdict, termination, exitCode, hitKind} from the return code of `rtb_exec_one`,
// `RTB_EXEC_{RC,STATE,TIMEDOUT,UNSUPPORTED,DECOY,UNRUNNABLE}` and the err hit lines. It takes no comparison side argument.
// Contract: detail plan `## comparison side result spec (#3068)`, docs/architecture/claude-code/test-result-contract.md.
// TL3 gap: does not produce the RTB_EXEC_* sets the real launcher and the outer watchdog (+10 seconds) emit; values are passed directly here.
const { isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const restore = isolate();
after(() => restore());

const MODULE = path.resolve(__dirname, "..", "..", "bin", "lib", "run-tests-baseline-comparison-side-result.js");
// While the module does not exist yet, each test fails with MODULE_NOT_FOUND (the whole file does not crash).
const parse = (...a) => require(MODULE).parseComparisonSideResult(...a);

const GUARD = "[run-all] command guard hit: node -e x";
const DECOY_LINE = "[run-all] root decoy hit: /tmp/decoy/bin/x";
const WT_LINE = "[run-all] worktree change: tests/x.sh";
const COUNT_GUARD = "[run-all] 2 command guard hits";
const COUNT_DECOY = "[run-all] 3 root decoy hits";

// Defaults when `rtb_exec_one` returned rc 0. Each case writes only its differences.
function ex(over) {
  return Object.assign({ returnCode: 0, RTB_EXEC_RC: "1", RTB_EXEC_STATE: "FAIL", RTB_EXEC_TIMEDOUT: "0",
    RTB_EXEC_UNSUPPORTED: "0", RTB_EXEC_DECOY: "0", RTB_EXEC_UNRUNNABLE: "0" }, over);
}
const R = (verdict, termination, exitCode, hitKind = "none") => ({ verdict, termination, exitCode, hitKind });

test("CSR-state: verdict / termination per state (PASS/FAIL/SKIP are completed, empty and unknown are ?/?)", () => {
  const cases = [
    { name: "PASS rc0", e: ex({ RTB_EXEC_STATE: "PASS", RTB_EXEC_RC: "0" }), want: R("PASS", "completed", 0) },
    { name: "FAIL rc1", e: ex({}), want: R("FAIL", "completed", 1) },
    { name: "FAIL rc3", e: ex({ RTB_EXEC_RC: "3" }), want: R("FAIL", "completed", 3) },
    { name: "FAIL rc124", e: ex({ RTB_EXEC_RC: "124" }), want: R("FAIL", "completed", 124) },
    { name: "FAIL rc137", e: ex({ RTB_EXEC_RC: "137" }), want: R("FAIL", "completed", 137) },
    { name: "SKIP rc77", e: ex({ RTB_EXEC_STATE: "SKIP", RTB_EXEC_RC: "77" }), want: R("SKIP", "completed", 77) },
    { name: "empty state rc0", e: ex({ RTB_EXEC_STATE: "", RTB_EXEC_RC: "0" }), want: R("?", "?", 0) },
    { name: "empty state rc143", e: ex({ RTB_EXEC_STATE: "", RTB_EXEC_RC: "143" }), want: R("?", "?", 143) },
    { name: "unknown state", e: ex({ RTB_EXEC_STATE: "WEIRD_X", RTB_EXEC_RC: "5" }), want: R("?", "?", 5) },
  ];
  for (const { name, e, want } of cases) {
    const got = parse(e, []);
    assert.deepEqual(got, want, `${name}`);
    assert.ok(!JSON.stringify(got).includes("WEIRD_X"), `${name}: does not carry the state string itself`);
  }
});

test("CSR-flags: setup failure, timeout vs the outer watchdog, unsupported, unrunnable, and the reading order", () => {
  const setup = ex({ returnCode: 2, RTB_EXEC_RC: "", RTB_EXEC_STATE: "" });
  const cases = [
    { name: "returnCode 2", e: setup, want: R("-", "launcher-setup-failed", null) },
    { name: "TIMEDOUT=1 state TIMEOUT", e: ex({ RTB_EXEC_TIMEDOUT: "1", RTB_EXEC_STATE: "TIMEOUT", RTB_EXEC_RC: "124" }),
      want: R("-", "timeout", 124) },
    { name: "TIMEDOUT=1 empty state (outer watchdog)", e: ex({ RTB_EXEC_TIMEDOUT: "1", RTB_EXEC_STATE: "", RTB_EXEC_RC: "137" }),
      want: R("-", "interrupted-by-outer-watchdog", 137) },
    { name: "TIMEDOUT=1 state FAIL (outer watchdog)", e: ex({ RTB_EXEC_TIMEDOUT: "1", RTB_EXEC_RC: "143" }),
      want: R("-", "interrupted-by-outer-watchdog", 143) },
    { name: "UNSUPPORTED=1", e: ex({ RTB_EXEC_UNSUPPORTED: "1", RTB_EXEC_STATE: "", RTB_EXEC_RC: "0" }), want: R("-", "unsupported", 0) },
    { name: "UNRUNNABLE=1", e: ex({ RTB_EXEC_UNRUNNABLE: "1", RTB_EXEC_RC: "1" }), want: R("-", "unrunnable", 1) },
    { name: "TIMEDOUT before UNSUPPORTED", e: ex({ RTB_EXEC_TIMEDOUT: "1", RTB_EXEC_STATE: "TIMEOUT", RTB_EXEC_RC: "124",
      RTB_EXEC_UNSUPPORTED: "1", RTB_EXEC_UNRUNNABLE: "1" }), want: R("-", "timeout", 124) },
    { name: "UNSUPPORTED before UNRUNNABLE", e: ex({ RTB_EXEC_UNSUPPORTED: "1", RTB_EXEC_UNRUNNABLE: "1" }),
      want: R("-", "unsupported", 1) },
    { name: "UNRUNNABLE before state", e: ex({ RTB_EXEC_UNRUNNABLE: "1", RTB_EXEC_STATE: "PASS", RTB_EXEC_RC: "0" }),
      want: R("-", "unrunnable", 0) },
  ];
  for (const { name, e, want } of cases) assert.deepEqual(parse(e, []), want, name);
});

test("CSR-hit-kind: the three hitKind values and the guard-line check (the same regex as `rtb_branch_guard_only_fail`)", () => {
  const cases = [
    { name: "DECOY=0, no hit line", decoy: "0", lines: [], want: "none" },
    { name: "DECOY=0, guard line", decoy: "0", lines: [GUARD], want: "none" },
    { name: "DECOY=1, guard line only", decoy: "1", lines: [GUARD], want: "command-guard-hit-only" },
    { name: "DECOY=1, two guard lines", decoy: "1", lines: [GUARD, GUARD], want: "command-guard-hit-only" },
    { name: "DECOY=1, no hit line", decoy: "1", lines: [], want: "root-decoy-or-worktree-change" },
    { name: "DECOY=1, root decoy line", decoy: "1", lines: [DECOY_LINE], want: "root-decoy-or-worktree-change" },
    { name: "DECOY=1, guard and root decoy", decoy: "1", lines: [GUARD, DECOY_LINE], want: "root-decoy-or-worktree-change" },
    { name: "DECOY=1, guard and worktree change", decoy: "1", lines: [GUARD, WT_LINE], want: "root-decoy-or-worktree-change" },
    { name: "DECOY=1, guard and root decoy count line", decoy: "1", lines: [GUARD, COUNT_DECOY], want: "root-decoy-or-worktree-change" },
    // The regex also excludes `[0-9]+ (root decoy hit|worktree change|command guard hit)` (as live does).
    { name: "DECOY=1, guard and guard count line", decoy: "1", lines: [GUARD, COUNT_GUARD], want: "root-decoy-or-worktree-change" },
    { name: "DECOY=1, guard line not starting with [run-all]", decoy: "1", lines: [" " + GUARD], want: "root-decoy-or-worktree-change" },
  ];
  // hitKind is decided independently of state (the state conditions sit in the decide rows).
  for (const state of [["FAIL", "1"], ["PASS", "0"], ["", "0"]]) {
    for (const { name, decoy, lines, want } of cases) {
      const got = parse(ex({ RTB_EXEC_STATE: state[0], RTB_EXEC_RC: state[1], RTB_EXEC_DECOY: decoy }), lines);
      assert.equal(got.hitKind, want, `state=${state[0] || "empty"} ${name}`);
    }
  }
});

test("CSR-shape: exactly four output fields, no comparison side argument, input left unchanged", () => {
  assert.equal(require(MODULE).parseComparisonSideResult.length, 2, "two arguments (execOutputs, errHitLines)");
  const samples = [ex({}), ex({ returnCode: 2, RTB_EXEC_RC: "", RTB_EXEC_STATE: "" }), ex({ RTB_EXEC_TIMEDOUT: "1" }),
    ex({ RTB_EXEC_DECOY: "1" }), ex({ RTB_EXEC_STATE: "", RTB_EXEC_RC: "77" })];
  for (const e of samples) {
    const lines = [GUARD];
    const before = JSON.stringify([e, lines]);
    const a = parse(e, lines);
    const b = parse(e, lines);
    assert.deepEqual(Object.keys(a).sort(), ["exitCode", "hitKind", "termination", "verdict"], `${before}: field`);
    assert.deepEqual(a, b, `${before}: same output from the same input`);
    assert.equal(JSON.stringify([e, lines]), before, `${before}: does not rewrite the input`);
    assert.ok(a.exitCode === null || Number.isInteger(a.exitCode), `${before}: exitCode is an integer or null`);
  }
});

test("CSR-invalid-input: throws when errHitLines is not an array or a field is missing", () => {
  const cases = [
    { name: "errHitLines is undefined", e: ex({}), lines: undefined },
    { name: "errHitLines is a string", e: ex({}), lines: GUARD },
    { name: "RTB_EXEC_STATE missing", e: (() => { const o = ex({}); delete o.RTB_EXEC_STATE; return o; })(), lines: [] },
    { name: "RTB_EXEC_DECOY missing", e: (() => { const o = ex({}); delete o.RTB_EXEC_DECOY; return o; })(), lines: [] },
    { name: "returnCode missing", e: (() => { const o = ex({}); delete o.returnCode; return o; })(), lines: [] },
    { name: "returnCode 0 with a non-numeric RC", e: ex({ RTB_EXEC_RC: "abc" }), lines: [] },
  ];
  // Load the module first (so a missing-module throw is not mistaken for an input-check throw).
  const { parseComparisonSideResult } = require(MODULE);
  for (const { name, e, lines } of cases) assert.throws(() => parseComparisonSideResult(e, lines), Error, name);
});
