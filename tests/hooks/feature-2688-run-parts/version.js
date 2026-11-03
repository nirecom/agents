"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, input-version, scope:issue-specific
// T7: every run_parts element carries the input_version of the tree it ran on. An element
// whose version differs from the latest one is dropped from the merge; a null version (no
// merge base against a protected branch) merges nothing.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("./drive");
const { check, eq, show } = F;
const { B, C } = D;

function versionMismatchDropsTheOlderPart() {
  const cwd = D.repo();
  const sid = D.session("ver");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  F.writeFiles(cwd, { "untracked-change.txt": "moves the input version\n" });
  D.dispatch(sid, cwd, 2, [B], { pass: 1 });
  check("T7: each run_parts element records its own input_version, and the two differ", () => {
    const p = D.parts(sid);
    if (p === null || p.length !== 2) return `run_parts=${show(F.runTests(sid).run_parts)}`;
    const [v1, v2] = p.map((e) => e.input_version);
    if (typeof v1 !== "string" || typeof v2 !== "string") return `versions ${show([v1, v2])}`;
    return v1 === v2 ? "the untracked change did not move input_version" : undefined;
  });
  check("T7: the stale full run is not merged — c's old failure does not hold run_tests (complete)", () => {
    eq(F.runTests(sid).status, "complete", "status");
  });
}

function nullVersionMergesNothing() {
  const cwd = D.repo({ branch: "topic" });
  const sid = D.session("null");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  D.dispatch(sid, cwd, 2, [B], { pass: 1 });
  check("T7: with no merge base every run_parts element has input_version null", () => {
    const p = D.parts(sid);
    if (p === null || p.length === 0) return `run_parts=${show(F.runTests(sid).run_parts)}`;
    const bad = p.filter((e) => !Object.prototype.hasOwnProperty.call(e, "input_version") || e.input_version !== null);
    return bad.length === 0 ? undefined : `elements ${show(bad)}`;
  });
  check("T7: with a null input_version the latest run decides alone (complete)", () => {
    eq(F.runTests(sid).status, "complete", "status");
  });
}

module.exports = { versionMismatchDropsTheOlderPart, nullVersionMergesNothing };
