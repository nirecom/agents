"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js, hooks/workflow-run-tests/record-run.js
// Tags: TL2, hooks, run-tests, run-parts, fail-closed, scope:issue-specific
// D2-11 through the real hook: a red part pushed out of the MAX_PARTS window by same-version
// green parts must keep run_tests open (truncated) until a full green run rebuilds run_parts.
// The window is filled by seeding run_parts; only the parts that overflow it go through the hook.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("../feature-2688-run-parts/drive");
const K = require("./kit");
const { check, eq } = F;
const { A, B } = D;

const MAX_PARTS = 50;
const OPEN = "(run-parts-open)";

function dispatchOut(sid, cwd, seq, testArgs, contract, failing) {
  const stem = F.placeOutcome(sid, { seq, cwd, testArgs, contract, failing: failing || [] });
  const r = K.poke(sid);
  if (!F.isIngested(sid, stem)) throw new Error(`fixture: ${stem} was not ingested`);
  return r;
}

// Proven green parts of B on the red part's input_version, as the hook records them.
function seedGreens(sid, count) {
  const prev = D.parts(sid);
  if (prev === null || prev.length !== 1 || typeof prev[0].input_version !== "string") {
    throw new Error(`fixture: want one versioned red part, got ${F.show(prev)}`);
  }
  const greens = Array.from({ length: count }, (_, i) => ({
    seq: prev[0].seq + i + 1, selection: [B], failing: [], exits: {}, hits: 0, hit_ids: [],
    hit_summary: [], unrunnable: 0, input_version: prev[0].input_version,
  }));
  F.seed(sid, [F.note("run_parts", prev.concat(greens))]);
}

// The red part of A, a full window behind it, then `overflows` green parts of B via the hook.
function overflowViaHook(tag, overflows) {
  const cwd = D.repo();
  const sid = K.session(tag);
  dispatchOut(sid, cwd, 1, [A], { fail: 1 }, [A]);
  seedGreens(sid, MAX_PARTS - 1);
  const outs = [];
  for (let i = 0; i < overflows; i++) outs.push(dispatchOut(sid, cwd, 2 + i, [B], { pass: 1 }).stdout);
  return { cwd, sid, outs, nextSeq: 2 + overflows };
}

const notComplete = (sid) => () => {
  const s = F.runTests(sid).status;
  return s !== "complete" ? null : "run_tests is complete";
};

function overflowHoldsOpen() {
  const { sid, outs } = overflowViaHook("ovf-open", 2);
  const parts = D.parts(sid) || [];
  check("D2-11: the window stays at MAX_PARTS", () => eq(parts.length, MAX_PARTS, "run_parts length"));
  check("D2-11: the red part left the window", () => (parts.some((e) => (e.failing || []).includes(A)) ? `run_parts=${F.show(parts)}` : null));
  check("D2-11: the pushing green part is marked truncated", () => eq(parts[parts.length - 1].truncated, true, "truncated"));
  outs.forEach((out, i) => {
    check(`D2-11: green overflow part ${i + 1} reports run-parts-open`, () => (out.includes(OPEN) ? null : `stdout lacks ${OPEN}: ${out}`));
  });
  check("D2-11: the last green part does not complete run_tests", notComplete(sid));
}

function fullRunAfterOverflowCompletes() {
  const { cwd, sid, nextSeq } = overflowViaHook("ovf-full", 1);
  check("D2-11: run_tests is open before the full run", notComplete(sid));
  dispatchOut(sid, cwd, nextSeq, [], { pass: 3 });
  check("D2-11: a full green run rebuilds run_parts to itself", () => eq(D.selections(sid), ["full"], "run_parts selections"));
  check("D2-11: the full green run completes run_tests", () => eq(F.runTests(sid).status, "complete", "status"));
}

module.exports = { overflowHoldsOpen, fullRunAfterOverflowCompletes };
