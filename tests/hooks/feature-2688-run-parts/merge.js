"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, dispatch-outcome, scope:issue-specific
// T7: the run_tests verdict merges partial reruns over the last full run, taking each
// rerun's selection from its own payload test_args. A test outside the selection keeps its
// earlier result; a later full run rebuilds the parts; a HIT is cleared only when its id
// is rerun clean; unrunnable never merges away.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("./drive");
const { check, eq } = F;
const { A, B, C } = D;

const HIT_B = `worktree-change ${B} tree=/x kind=tracked paths=a.txt`;
const HIT_NOID = "command-guard (no test id) gh --version";

function mergesWorkerSelections() {
  const cwd = D.repo();
  const sid = D.session("merge");
  D.dispatch(sid, cwd, 1, [], { pass: 1, fail: 2 }, [B, C]);
  D.dispatch(sid, cwd, 2, [B], { pass: 1 });
  check("T7: a rerun of [b] keeps c's failure from the full run (pending, failing [c])", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [C], "failing_tests");
  });
  check("T7: run_parts holds the full run and the [b] selection", () => {
    eq(D.selections(sid), ["full", [B]], "selections");
  });
  D.dispatch(sid, cwd, 3, [C], { pass: 1 });
  check("T7: rerunning the last failing test completes run_tests", () => {
    eq(F.runTests(sid).status, "complete", "status");
  });
}

function fullRunRebuilds() {
  const cwd = D.repo();
  const sid = D.session("full");
  D.dispatch(sid, cwd, 1, [], { pass: 2, fail: 1 }, [A]);
  D.dispatch(sid, cwd, 2, [A], { pass: 1 });
  D.dispatch(sid, cwd, 3, [], { pass: 2, fail: 1 }, [B]);
  check("T7: a later full run decides alone (failing [b])", () => {
    eq(F.runTests(sid).status, "pending", "status");
    eq(D.failing(sid), [B], "failing_tests");
  });
  check("T7: a later full run rebuilds run_parts to one full element", () => {
    eq(D.selections(sid), ["full"], "selections");
  });
}

function hitClearedOnlyWhenRerunClean() {
  const cwd = D.repo();
  const both = D.session("hit-both");
  D.dispatch(both, cwd, 1, [], { pass: 3, hits: 2 }, [], [HIT_B, HIT_NOID]);
  D.dispatch(both, cwd, 2, [B], { pass: 1 });
  check("T7: rerunning b clean clears b's HIT; the no-id HIT stays (pending, hit_count 1)", () => {
    const rt = F.runTests(both);
    eq(rt.status, "pending", "status");
    eq(rt.hit_count, 1, "hit_count");
    const s = JSON.stringify(rt.hit_summary || null);
    if (s.includes(HIT_B)) return `b's HIT survived: ${s}`;
    if (!s.includes("command-guard")) return `the no-id HIT was dropped: ${s}`;
    return undefined;
  });

  const other = D.session("hit-other");
  D.dispatch(other, cwd, 1, [], { pass: 3, hits: 1 }, [], [HIT_B]);
  D.dispatch(other, cwd, 2, [A], { pass: 1 });
  check("T7: rerunning a test other than the HIT id leaves the HIT (pending, hit_count 1)", () => {
    const rt = F.runTests(other);
    eq(rt.status, "pending", "status");
    eq(rt.hit_count, 1, "hit_count");
  });

  const dirty = D.session("hit-dirty");
  D.dispatch(dirty, cwd, 1, [], { pass: 3, hits: 1 }, [], [HIT_B]);
  D.dispatch(dirty, cwd, 2, [B], { pass: 1, hits: 1 }, [], [HIT_B]);
  check("T7: a rerun that HITs again does not clear the HIT (pending)", () => {
    eq(F.runTests(dirty).status, "pending", "status");
  });

  const clean = D.session("hit-clean");
  D.dispatch(clean, cwd, 1, [], { pass: 3, hits: 1 }, [], [HIT_B]);
  D.dispatch(clean, cwd, 2, [B], { pass: 1 });
  check("T7: the only HIT rerun clean completes run_tests", () => {
    eq(F.runTests(clean).status, "complete", "status");
  });
}

function unrunnableNeverMergesAway() {
  const cwd = D.repo();
  const sid = D.session("unrunnable");
  D.dispatch(sid, cwd, 1, [], { pass: 2, unrunnable: 1 });
  D.dispatch(sid, cwd, 2, [B], { pass: 1 });
  check("T7: an unrunnable count in the full run survives a clean rerun (pending, unrunnable_count > 0)", () => {
    const rt = F.runTests(sid);
    eq(rt.status, "pending", "status");
    if (!(rt.unrunnable_count > 0)) return `unrunnable_count=${JSON.stringify(rt.unrunnable_count)}`;
    return undefined;
  });
}

module.exports = { mergesWorkerSelections, fullRunRebuilds, hitClearedOnlyWhenRerunClean, unrunnableNeverMergesAway };
