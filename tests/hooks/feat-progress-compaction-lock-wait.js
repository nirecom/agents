#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/progress-compaction.js
// Tags: TL1, hooks, progress-nudge, compaction, lock-timeout, fail-open, regression, scope:common
// #2594: recordCompaction waits a bounded COMPACTION_LOCK_WAIT_MS (1 s) for the progress-pressure
// lock, well under the 5 s PostCompact hook timeout; a timeout drops the record (null) and leaves
// the pressure state untouched, and the next compaction with the lock free records normally.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");

const restore = isolate();

const ROOT = path.join(__dirname, "..", "..");
const PC = require(path.join(ROOT, "hooks", "lib", "progress-compaction"));
const PF = require(path.join(ROOT, "hooks", "lib", "progress-file"));
const { sidecarPath } = require(path.join(ROOT, "hooks", "lib", "control-sidecar"));

let passed = 0;
let failed = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const failures = () => failed;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
});

// The real lock updatePressure takes; a token naming a live pid with a fresh mtime is never stolen early.
const lockPathOf = (sid) => `${sidecarPath(sid, PF.PRESSURE_SUFFIX, { forWrite: true })}.lock`;
const holdLock = (sid) => fs.writeFileSync(lockPathOf(sid), `${process.pid}.held-by-test`);
const freeLock = (sid) => fs.rmSync(lockPathOf(sid), { force: true });
const pressure = (sid) => PF.readPressure(sid);
const compactions = (sid) => ((pressure(sid) || {}).compactions_at || []).length;

function timed(fn) {
  const t0 = Date.now();
  const out = fn();
  return { out, elapsed: Date.now() - t0 };
}

const SID = "pcl-locked";
const T0 = Date.UTC(2026, 9, 18, 12, 0, 0);

caseBegin("live-lock-held-drops-record-within-bound", "hooks/lib/progress-compaction.js");
test("live-lock-held-drops-record-within-bound", () => noNewFailures(failures, () => {
  check("A1: fixture — a prior pressure record exists", () => eq(PF.mergePressure(SID, { event_cursor: 3 }), true, "mergePressure"));
  holdLock(SID);
  const before = pressure(SID);
  const { out, elapsed } = timed(() => PC.recordCompaction(SID, T0));
  freeLock(SID);
  check("A1: with a live-holder lock held recordCompaction returns null", () => eq(out, null, "result"));
  check(`A1: the lock-blocked call returns in under 4000 ms (elapsed=${elapsed})`, () => eq(elapsed < 4000, true, "under 4000 ms"));
  check(`A1: the lock-blocked call waits the bound rather than failing instantly (elapsed=${elapsed})`, () => eq(elapsed >= 800, true, ">= 800 ms"));
  check("A1: the pressure state is unchanged (no compactions_at added)", () => eq(pressure(SID), before, "progress-pressure.json"));
}));
caseEnd();

caseBegin("lock-released-first-compaction-records-pending", "hooks/lib/progress-compaction.js");
test("lock-released-first-compaction-records-pending", () => noNewFailures(failures, () => {
  const out = PC.recordCompaction(SID, T0 + 1000);
  const cur = pressure(SID) || {};
  check("A2: after release the first compaction returns {pending:true, burst:false}", () => eq(out, { pending: true, burst: false }, "result"));
  check("A2: compactions_at has length 1", () => eq(compactions(SID), 1, "compactions_at length"));
  check("A2: compaction_pending is true", () => eq(cur.compaction_pending, true, "compaction_pending"));
}));
caseEnd();

caseBegin("second-compaction-not-pending-and-grows", "hooks/lib/progress-compaction.js");
test("second-compaction-not-pending-and-grows", () => noNewFailures(failures, () => {
  const out = PC.recordCompaction(SID, T0 + 2000);
  check("A3: the second compaction returns pending:false", () => eq(out && out.pending, false, "pending"));
  check("A3: compactions_at grows to 2", () => eq(compactions(SID), 2, "compactions_at length"));
}));
caseEnd();

caseBegin("no-lock-returns-promptly-and-records", "hooks/lib/progress-compaction.js");
test("no-lock-returns-promptly-and-records", () => noNewFailures(failures, () => {
  const sid = "pcl-free";
  const { out, elapsed } = timed(() => PC.recordCompaction(sid, T0));
  check(`A4: with no lock held recordCompaction returns in under 1000 ms (elapsed=${elapsed})`, () => eq(elapsed < 1000, true, "under 1000 ms"));
  check("A4: with no lock held the compaction is recorded", () => eq([out, compactions(sid)], [{ pending: true, burst: false }, 1], "[result, compactions_at length]"));
}));
caseEnd();

// A child process holds the live-holder lock and releases it mid-wait: the parent's wait is synchronous.
const RELEASE_AFTER_MS = 500;
const CHILD_SRC = `const fs=require("fs");const l=process.argv[1];fs.writeFileSync(l,process.pid+".held-by-test");setTimeout(()=>{fs.rmSync(l,{force:true});},${RELEASE_AFTER_MS});`;
function waitForFile(p, maxMs) {
  const end = Date.now() + maxMs;
  while (Date.now() < end) {
    if (fs.existsSync(p)) return true;
  }
  return fs.existsSync(p);
}

caseBegin("lock-released-mid-wait-records-once", "hooks/lib/progress-compaction.js");
test("lock-released-mid-wait-records-once", () => noNewFailures(failures, () => {
  const sid = "pcl-midwait";
  const lock = lockPathOf(sid);
  const child = spawn(process.execPath, ["-e", CHILD_SRC, lock], { stdio: "ignore" });
  try {
    const held = waitForFile(lock, 10000);
    check("A5: fixture — the child holds the lock before recordCompaction is called", () => eq(held, true, "lock present"));
    const { out, elapsed } = held ? timed(() => PC.recordCompaction(sid, T0)) : { out: undefined, elapsed: -1 };
    check("A5: a lock released mid-wait lets the compaction record ({pending:true})", () => eq(out, { pending: true, burst: false }, "result"));
    check(`A5: the call waited for the release and stayed within the bound (200 <= elapsed < 1500, elapsed=${elapsed})`, () => eq(elapsed >= 200 && elapsed < 1500, true, "elapsed in range"));
    check("A5: the compaction is recorded exactly once", () => eq(compactions(sid), 1, "compactions_at length"));
    check("A5: no lock file is left behind", () => eq(fs.existsSync(lock), false, "lock exists"));
  } finally {
    try { child.kill(); } catch (_) { /* already exited */ }
    freeLock(sid);
  }
}));
caseEnd();
