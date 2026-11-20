"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, state-lock, concurrency, fail-closed, scope:issue-specific
// #3073 C1: applyDispatchOutcome runs scan -> record -> mark -> supersede under one state lock.
// A second process holding the lock (lock-child.js hold) makes a real applyDispatchOutcome child
// wait before it scans, so it re-scans after the wait and never records a stem twice nor an
// older green over a newer failure; a lock it cannot keep leaves no partial ingest.

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const F = require("../../lib/run-tests-outcome-fixture");
const D = require("../feature-2688-run-parts/drive");
const { check, eq, show } = F;
const { A } = D;

const CHILD = path.join(__dirname, "lock-child.js");
// The one state-lock timeout these cases assume (state-lock.js DEFAULT_TIMEOUT_MS, which it does
// not export today); every wait, budget and child limit below derives from it.
const LOCK_TIMEOUT_MS = (() => {
  const v = F.mod("hooks/workflow-state/state-io/state-lock.js").DEFAULT_TIMEOUT_MS;
  return typeof v === "number" && v > 0 ? v : 3000;
})();
const WAIT_MS = LOCK_TIMEOUT_MS * 10;
const HOLD_BUDGET_MS = LOCK_TIMEOUT_MS / 2;
const GREEN_FULL = { testArgs: [], contract: { pass: 3 } };
const RED_FULL = { testArgs: [], contract: { pass: 2, fail: 1 }, failing: [A] };

let n = 0;
const live = new Set();
process.on("exit", () => {
  for (const c of live) c.kill();
});

function scenario(tag) {
  const sid = `s-3073-lock-${tag}-${++n}`;
  F.seedPrefix(sid);
  const dir = path.join(F.tmp(), `lock-${tag}-${n}`);
  fs.mkdirSync(dir, { recursive: true });
  return { sid, dir, cwd: D.repo() };
}

const touch = (dir, name) => fs.writeFileSync(path.join(dir, name), "1\n");
// apply.log lines are "<event> <epoch-ms>"; events are in write order.
const logEntries = (dir) => {
  const p = path.join(dir, "apply.log");
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => {
    const [event, at] = l.split(" ");
    return { event, at: Number(at) };
  });
};
const logLines = (dir) => logEntries(dir).map((e) => e.event);
const firstAt = (entries, event) => {
  const e = entries.find((x) => x.event === event);
  return e ? e.at : null;
};

function child(mode, s) {
  const env = Object.assign({}, process.env, { F3073_LOCK_TIMEOUT_MS: String(LOCK_TIMEOUT_MS) });
  const c = spawn(process.execPath, [CHILD, mode, s.sid, s.dir], { cwd: F.tmp(), env, stdio: ["ignore", "pipe", "pipe"] });
  live.add(c);
  let stdout = "";
  let stderr = "";
  c.stdout.on("data", (b) => { stdout += b; });
  c.stderr.on("data", (b) => { stderr += b; });
  const done = new Promise((resolve) => {
    const t = setTimeout(() => c.kill(), WAIT_MS * 2);
    c.on("close", (code) => {
      clearTimeout(t);
      live.delete(c);
      let result = null;
      try { result = JSON.parse(stdout.trim().split("\n").pop()); } catch (_) { /* reported below */ }
      resolve({ code, stdout, stderr, result });
    });
  });
  return { done };
}

async function until(pred, what) {
  const deadline = Date.now() + WAIT_MS;
  while (!pred()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}
const fileAt = (dir, name) => () => fs.existsSync(path.join(dir, name));

// Annotation events naming `stem` as the outcome a run was recorded from.
const recordsOf = (sid, stem) => (F.state(sid).events || []).filter((e) =>
  e.kind === "step_annotation" && e.step === "run_tests" && e.key === "outcome_source" && e.value && e.value.stem === stem).length;
const unconsumed = (sid) => (F.mod("hooks/workflow-state/dispatch-settlement.js")
  .listUnconsumed({ sessionId: sid, worker: "test-runner" }).stems || []).map((d) => d.stem);

// The race: `apply` starts while `hold` has the lock and reaches the lock wait; then `hold`
// ingests in-process (after `beforeIngest` places more outcomes) and releases.
async function race(tag, beforeIngest) {
  const s = scenario(tag);
  const seen = { sid: s.sid };
  seen.older = F.placeOutcome(s.sid, Object.assign({ seq: 1, cwd: s.cwd }, GREEN_FULL));
  const holder = child("hold", s);
  await until(fileAt(s.dir, "held"), "the holder to take the lock");
  seen.eventsBefore = F.eventCount(s.sid);
  const applier = child("apply", s);
  await until(() => logLines(s.dir).includes("lock-wait"), "the applier to wait on the lock");
  seen.eventsWhileHeld = F.eventCount(s.sid);
  seen.ingestedWhileHeld = F.isIngested(s.sid, seen.older);
  if (beforeIngest) seen.newer = beforeIngest(s);
  touch(s.dir, "ingest");
  touch(s.dir, "go");
  await until(fileAt(s.dir, "ingest-done"), "the holder's ingest");
  seen.eventsAfterHolder = F.eventCount(s.sid);
  seen.recordsAfterHolder = recordsOf(s.sid, seen.older);
  touch(s.dir, "release");
  seen.holder = await holder.done;
  seen.applier = await applier.done;
  const entries = logEntries(s.dir);
  seen.log = entries.map((e) => e.event);
  const waitAt = firstAt(entries, "lock-wait");
  const acquiredAt = firstAt(entries, "lock-acquired");
  seen.waitedMs = waitAt !== null && acquiredAt !== null ? acquiredAt - waitAt : null;
  seen.eventsAfter = F.eventCount(s.sid);
  seen.recordsAfter = recordsOf(s.sid, seen.older);
  seen.entry = F.runTests(s.sid);
  return seen;
}

const applierOk = (s) => (s.applier.result && s.applier.result.ok ? null
  : `applier: ${show(s.applier.result)} exit ${s.applier.code} stderr ${s.applier.stderr.slice(0, 300)}`);

// Fixture guard: the race is only meaningful when the holder released well inside the timeout.
function holdWithinBudget(tag, s) {
  check(`C1 ${tag}: fixture — the applier's lock wait stayed within ${HOLD_BUDGET_MS}ms (timeout ${LOCK_TIMEOUT_MS}ms)`, () => {
    if (s.waitedMs === null) return `no lock-wait / lock-acquired pair in ${show(s.log)}`;
    return s.waitedMs <= HOLD_BUDGET_MS ? null : `waited ${s.waitedMs}ms`;
  });
}

async function lockWaitDefersScan() {
  const s = await race("wait");
  holdWithinBudget("wait", s);
  check("C1 wait: nothing is recorded or marked while another process holds the lock", () => {
    eq(s.eventsWhileHeld, s.eventsBefore, "event count while held");
    eq(s.ingestedWhileHeld, false, ".ingested while held");
  });
  check("C1 wait: the applier scans the control dir only after it holds the lock", () => {
    const scan = s.log.indexOf("scan");
    const acquired = s.log.indexOf("lock-acquired");
    if (scan === -1 || acquired === -1) return `log lacks scan or lock-acquired: ${show(s.log)}`;
    return scan > acquired ? null : `scan before the lock: ${show(s.log)}`;
  });
  check("C1 wait: the waiting applier completes once the lock is released", () => applierOk(s));
}

async function waitedCallRescans() {
  const s = await race("rescan");
  holdWithinBudget("rescan", s);
  check("C1 rescan: the holder's in-process ingest recorded the stem once", () => eq(s.recordsAfterHolder, 1, "records after holder"));
  check("C1 rescan: the waited call records nothing for the already-ingested stem", () => {
    eq(s.recordsAfter, 1, `records of ${s.older}`);
    eq(s.eventsAfter, s.eventsAfterHolder, "event count across the waited call");
  });
  check("C1 rescan: the waited call reports no ingest of its own", () => {
    const why = applierOk(s);
    if (why) return why;
    eq(s.applier.result.ingested, false, "ingested");
    return undefined;
  });
}

async function oldGreenKeepsNewFailure() {
  const s = await race("green-red", (sc) => F.placeOutcome(sc.sid, Object.assign({ seq: 2, cwd: sc.cwd }, RED_FULL)));
  holdWithinBudget("order", s);
  check("C1 order: both outcomes end ingested", () => eq([F.isIngested(s.sid, s.older), F.isIngested(s.sid, s.newer)], [true, true], "ingested [older, newer]"));
  check("C1 order: the older green is not recorded again after the newer failure", () => eq(s.recordsAfter, s.recordsAfterHolder, `records of ${s.older}`));
  check("C1 order: run_tests keeps the newer failure and stays pending", () => {
    eq(s.entry.status, "pending", "status");
    eq(s.entry.failing_tests, [A], "failing_tests");
    eq(s.entry.outcome_source && s.entry.outcome_source.stem, s.newer, "outcome_source.stem");
  });
  check("C1 order: the waited call completes", () => applierOk(s));
}

// The lock stays held by another process for the applier's whole call.
async function lockTimeoutRecordsNothing() {
  const s = scenario("timeout");
  const stem = F.placeOutcome(s.sid, Object.assign({ seq: 1, cwd: s.cwd }, GREEN_FULL));
  const holder = child("hold", s);
  await until(fileAt(s.dir, "held"), "the holder to take the lock");
  const before = F.eventCount(s.sid);
  const applier = await child("apply", s).done;
  const after = F.eventCount(s.sid);
  const log = logLines(s.dir);
  touch(s.dir, "go");
  touch(s.dir, "release");
  await holder.done;
  check("C1 timeout: the applier gives up with StateLockTimeoutError", () => {
    const r = applier.result;
    if (r && r.ok === false && r.name === "StateLockTimeoutError") return null;
    return `applier: ${show(r)} exit ${applier.code} stderr ${applier.stderr.slice(0, 300)}`;
  });
  check("C1 timeout: the applier waited on the state lock and never acquired it", () => {
    if (!log.includes("lock-wait")) return `no lock-wait in ${show(log)}`;
    return log.includes("lock-acquired") ? `lock-acquired in ${show(log)}` : null;
  });
  check("C1 timeout: no run is recorded and no .ingested marker is written", () => {
    eq(after, before, "event count");
    eq(F.isIngested(s.sid, stem), false, ".ingested");
  });
  check("C1 timeout: the outcome stays unconsumed and run_tests is not complete", () => {
    eq(unconsumed(s.sid), [stem], "unconsumed stems");
    if (F.runTests(s.sid).status === "complete") return "run_tests became complete";
    return undefined;
  });
}

// Another process asks for the lock right after the applier's first .ingested marker: the applier
// must still hold it, so either every stem of its scan lands or none does — never only the green.
async function lockLossMidIngestLeavesNoPartial() {
  const s = scenario("partial");
  const older = F.placeOutcome(s.sid, Object.assign({ seq: 1, cwd: s.cwd }, GREEN_FULL));
  const newer = F.placeOutcome(s.sid, Object.assign({ seq: 2, cwd: s.cwd }, RED_FULL));
  touch(s.dir, "wait-acquire");
  touch(s.dir, "pause");
  const holder = child("hold", s);
  const applierRun = child("apply", s);
  await until(fileAt(s.dir, "paused"), "the applier's first .ingested marker");
  touch(s.dir, "acquire");
  const applier = await applierRun.done;
  const marks = [F.isIngested(s.sid, older), F.isIngested(s.sid, newer)];
  const entry = F.runTests(s.sid);
  touch(s.dir, "go");
  touch(s.dir, "release");
  await holder.done;
  check("C1 partial: the dispatches of one scan are ingested all or none", () => {
    if (marks[0] === marks[1]) return null;
    return `partial ingest [older, newer]=${show(marks)}; applier ${show(applier.result)}`;
  });
  check("C1 partial: run_tests is not complete while the newer failing outcome exists", () => {
    if (entry.status === "complete") return `complete on the older green; applier ${show(applier.result)}`;
    return undefined;
  });
}

async function reentrantCallCompletes() {
  const s = scenario("reenter");
  const stem = F.placeOutcome(s.sid, Object.assign({ seq: 1, cwd: s.cwd }, GREEN_FULL));
  const r = await child("reenter", s).done;
  check("C1 reenter: applyDispatchOutcome inside the same process's lock completes", () => {
    if (r.result && r.result.ok === true && r.result.ingested === true) return null;
    return `reenter: ${show(r.result)} exit ${r.code} stderr ${r.stderr.slice(0, 300)}`;
  });
  check("C1 reenter: the stem is recorded once and marked ingested", () => {
    eq(recordsOf(s.sid, stem), 1, "records");
    eq(F.isIngested(s.sid, stem), true, ".ingested");
    eq(F.runTests(s.sid).status, "complete", "status");
  });
}

module.exports = {
  lockWaitDefersScan, waitedCallRescans, oldGreenKeepsNewFailure,
  lockTimeoutRecordsNothing, lockLossMidIngestLeavesNoPartial, reentrantCallCompletes,
  // shared with lock-hook.js
  scenario, touch, child, until, fileAt, unconsumed, WAIT_MS, GREEN_FULL,
};
