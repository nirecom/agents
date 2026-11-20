"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, fail-closed, scope:issue-specific
// T-D1 / T-D2 / T-D4 / T-D5: every unconsumed test-runner dispatch counts, not only the latest.
// Two trusted outcomes both land; an older absent or untrusted one keeps run_tests pending;
// a late outcome only adds its failure; a full green run supersedes an older absent stem.

const F = require("../../lib/run-tests-outcome-fixture");
const D = require("../feature-2688-run-parts/drive");
const K = require("./kit");
const { check, eq } = F;
const { A, B } = D;

const settlement = () => F.mod("hooks/workflow-state/dispatch-settlement.js");
const unsettledStems = (sid) => (settlement().listUnsettled({ sessionId: sid }).unsettled || []).map((u) => u.stem);

function bothTrustedDispatchesIngested() {
  const cwd = D.repo();
  const sid = K.session("both");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], contract: { fail: 1 }, failing: [A] });
  const b = K.place(sid, { seq: 2, cwd, testArgs: [B], contract: { fail: 1 }, failing: [B] });
  K.poke(sid);
  check("T-D1: one hook call ingests both unconsumed stems", () => {
    eq([F.isIngested(sid, a), F.isIngested(sid, b)], [true, true], "ingested [a, b]");
  });
  check("T-D1: failing_tests holds the failures of both dispatches", () => eq(D.failing(sid), [A, B], "failing_tests"));
  check("T-D1: run_tests is not complete", () => eq(F.runTests(sid).status, "pending", "status"));
  check("T-D1: the baseline rerun-list entry reads both failures", () => {
    const r = K.rerunList(sid);
    eq(r.code, 0, "rerun-list code");
    eq((r.stdout || "").split("\n").filter(Boolean).sort(), [A, B], "rerun-list paths");
  });
  const before = F.eventCount(sid);
  K.poke(sid);
  check("T-D1: a second hook call records nothing more (idempotent)", () => eq(F.eventCount(sid), before, "event count"));
}

function preconditionListsEveryUnsettledStem() {
  const cwd = D.repo();
  const sid = K.session("pre");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], absent: true });
  const b = K.place(sid, { seq: 2, cwd, testArgs: [B], absent: true });
  const got = K.precondition(sid, { outcome_source: null });
  check("T-D1: dispatchPrecondition refuses while two dispatches are unsettled", () => {
    if (typeof got !== "string") return `want a refusal string, got ${F.show(got)}`;
    return got.includes("a test-runner dispatch has not settled") ? null : `message: ${got}`;
  });
  check("T-D1: the refusal names both unsettled stems", () => {
    const missing = [a, b].filter((s) => !String(got).includes(s));
    return missing.length === 0 ? null : `stems not named: ${missing.join(", ")} in ${F.show(got)}`;
  });
}

// An older dispatch whose outcome cannot be used (o: { absent } or { untrusted }) beside a green newer one.
function olderUnusableStemBlocks(tag, o) {
  const cwd = D.repo();
  const sid = K.session(tag);
  const a = K.place(sid, Object.assign({ seq: 1, cwd, testArgs: [A], contract: { fail: 1 }, failing: [A] }, o));
  const b = K.place(sid, { seq: 2, cwd, testArgs: [B], contract: { pass: 1 } });
  const r = K.poke(sid);
  return { sid, a, b, stdout: r.stdout };
}

function absentOlderStemBlocksCompletion() {
  const { sid, a, b, stdout } = olderUnusableStemBlocks("absent", { absent: true });
  check("T-D2: the newer green outcome is ingested", () => eq(F.isIngested(sid, b), true, "b ingested"));
  check("T-D2: run_tests is not complete while the older outcome is absent", () => eq(F.runTests(sid).status, "pending", "status"));
  check("T-D2: dispatch_unsettled names the older absent stem", () => eq(F.runTests(sid).dispatch_unsettled, a, "dispatch_unsettled"));
  check("T-D2: the hook reports dispatch-unsettled", () => (stdout.includes("(dispatch-unsettled)") ? null : `stdout: ${stdout}`));
  check("T-D2: listUnsettled returns the older absent stem", () => eq(unsettledStems(sid).includes(a), true, `a in ${F.show(unsettledStems(sid))}`));
}

function untrustedOlderStemBlocksCompletion() {
  const { sid, a } = olderUnusableStemBlocks("untrusted", { untrusted: true });
  check("untrusted: run_tests is not complete while the older outcome is untrusted", () => eq(F.runTests(sid).status, "pending", "status"));
  check("untrusted: dispatch_unsettled names the untrusted stem", () => eq(F.runTests(sid).dispatch_unsettled, a, "dispatch_unsettled"));
  check("untrusted: the untrusted stem is never marked ingested", () => eq(F.isIngested(sid, a), false, "a ingested"));
}

function lateOutcomeAddsItsFailure() {
  const cwd = D.repo();
  const sid = K.session("late");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], absent: true });
  const b = K.place(sid, { seq: 2, cwd, testArgs: [B], contract: { pass: 1 } });
  K.poke(sid);
  K.land(sid, { seq: 1, cwd, testArgs: [A], contract: { fail: 1 }, failing: [A] });
  K.poke(sid);
  check("T-D4: the late outcome is ingested", () => eq(F.isIngested(sid, a), true, "a ingested"));
  check("T-D4: the late failure is added to failing_tests", () => {
    const f = D.failing(sid);
    return Array.isArray(f) && f.includes(A) ? null : `failing_tests=${F.show(f)}`;
  });
  check("T-D4: run_tests is not complete", () => eq(F.runTests(sid).status, "pending", "status"));
  check("T-D4: the earlier-ingested result stays (b ingested, its [b] part kept)", () => {
    eq(F.isIngested(sid, b), true, "b ingested");
    const s = D.selections(sid) || [];
    return s.some((e) => JSON.stringify(e) === JSON.stringify([B])) ? null : `run_parts selections=${F.show(s)}`;
  });
}

function fullRunSupersedesAbsentStem() {
  const cwd = D.repo();
  const sid = K.session("supersede");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], absent: true });
  const c = K.place(sid, { seq: 3, cwd, testArgs: [], contract: { pass: 3 } });
  K.poke(sid);
  check("T-D5: the full green run is ingested", () => eq(F.isIngested(sid, c), true, "c ingested"));
  check("T-D5: the older absent stem is superseded (marked ingested)", () => eq(F.isIngested(sid, a), true, "a ingested"));
  check("T-D5: dispatch_unsettled is re-picked to none", () => {
    const v = F.runTests(sid).dispatch_unsettled;
    return v === null || v === undefined ? null : `dispatch_unsettled=${F.show(v)}`;
  });
  check("T-D5: run_tests is complete", () => eq(F.runTests(sid).status, "complete", "status"));
}

// A full failing run supersedes an older absent stem too; its own failure is what stays.
function fullRedRunSupersedesAbsentStem() {
  const cwd = D.repo();
  const sid = K.session("supersede-red");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], absent: true });
  K.place(sid, { seq: 3, cwd, testArgs: [], contract: { pass: 2, fail: 1 }, failing: [B] });
  K.poke(sid);
  check("T-D5 red: the older absent stem is superseded (marked ingested)", () => eq(F.isIngested(sid, a), true, "a ingested"));
  check("T-D5 red: dispatch_unsettled is re-picked to none", () => {
    const v = F.runTests(sid).dispatch_unsettled;
    return v === null || v === undefined ? null : `dispatch_unsettled=${F.show(v)}`;
  });
  check("T-D5 red: failing_tests holds the full run's failure", () => eq(D.failing(sid), [B], "failing_tests"));
  check("T-D5 red: run_tests is not complete", () => eq(F.runTests(sid).status, "pending", "status"));
}

// seq 1 stays absent while seq 2 is ingested, then seq 1 lands: the late arrival.
function lateArrival(tag, older, newer) {
  const cwd = D.repo();
  const sid = K.session(tag);
  const a = K.place(sid, Object.assign({ seq: 1, cwd, absent: true }, older, { contract: undefined, failing: undefined }));
  K.place(sid, Object.assign({ seq: 2, cwd }, newer));
  K.poke(sid);
  if (F.isIngested(sid, a)) throw new Error("fixture: the older stem was ingested before it landed");
  K.land(sid, Object.assign({ seq: 1, cwd }, older));
  K.poke(sid);
  if (!F.isIngested(sid, a)) throw new Error("fixture: the late outcome was not ingested");
  return sid;
}

function lateFullGreenDoesNotRebuild() {
  const sid = lateArrival("late-full", { testArgs: [], contract: { pass: 3 } }, { testArgs: [A, B], contract: { pass: 1, fail: 1 }, failing: [A] });
  check("T-D4 late full: the newer run's failure is kept", () => {
    const f = D.failing(sid);
    return Array.isArray(f) && f.includes(A) ? null : `failing_tests=${F.show(f)}`;
  });
  check("T-D4 late full: run_parts is not rebuilt to the late full part", () => {
    const s = D.selections(sid) || [];
    return s.some((e) => JSON.stringify(e) === JSON.stringify([A, B])) ? null : `run_parts selections=${F.show(s)}`;
  });
  check("T-D4 late full: run_tests is not complete", () => eq(F.runTests(sid).status, "pending", "status"));
}

function lateGreenPathKeepsNewerFailure() {
  const sid = lateArrival("late-path", { testArgs: [A], contract: { pass: 1 } }, { testArgs: [A, B], contract: { pass: 1, fail: 1 }, failing: [A] });
  check("T-D4 late [a]: a late green [a] does not erase the newer run's a failure", () => {
    const f = D.failing(sid);
    return Array.isArray(f) && f.includes(A) ? null : `failing_tests=${F.show(f)}`;
  });
  check("T-D4 late [a]: run_tests is not complete", () => eq(F.runTests(sid).status, "pending", "status"));
}

function listUnconsumedMarksLateStems() {
  const cwd = D.repo();
  const sid = K.session("late-probe");
  const a = K.place(sid, { seq: 1, cwd, testArgs: [A], absent: true });
  K.place(sid, { seq: 2, cwd, testArgs: [B], contract: { pass: 1 } });
  K.poke(sid);
  const c = K.place(sid, { seq: 3, cwd, testArgs: [B], absent: true });
  const got = settlement().listUnconsumed({ sessionId: sid, worker: "test-runner" });
  check("late probe: listUnconsumed marks the stem older than an ingested one late, the newer one not", () => {
    eq((got.stems || []).map((d) => [d.stem, d.late]), [[a, true], [c, false]], "[stem, late]");
  });
}

module.exports = {
  bothTrustedDispatchesIngested, preconditionListsEveryUnsettledStem, absentOlderStemBlocksCompletion,
  untrustedOlderStemBlocksCompletion, lateOutcomeAddsItsFailure, fullRunSupersedesAbsentStem,
  fullRedRunSupersedesAbsentStem, lateFullGreenDoesNotRebuild, lateGreenPathKeepsNewerFailure,
  listUnconsumedMarksLateStems,
};
