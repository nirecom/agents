"use strict";
// The PC-wide PM lock (#2942): every PM write path (init, add, remove, inherit, rename, set-sequence,
// set-reason) runs inside withPmLock, so two writers never interleave their checks and writes.
// The file <state root>/pm.lock holds {pid, start_ms, token, host, at}. A holder is stolen only when it
// is provably gone: its pid is dead, or the pid is alive with a start time more than START_SLACK_MS
// away from start_ms (pid reuse). An unreadable start time counts as live. A live holder older than
// PM_LOCK_STALE_MS is refused at once with the manual release steps; a fresh one is waited for.

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { listStateRoots } = require("../workflow-state/state-io/state-root");
const PST = require("../lib/process-start-time");

const PM_LOCK_STALE_MS = 15000;
const PM_LOCK_WAIT_MS = 1500;
const START_SLACK_MS = 2000;
const POLL_MS = 50;
const START_TIME_TIMEOUT_MS = 1000;

class PmLockBusy extends Error {
  constructor(message) { super(`pm-lock-busy: ${message}`); this.reason = "pm-lock-busy"; }
}

const lockPath = () => path.join(listStateRoots()[0], "pm.lock");
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.max(1, ms));

function readLock(file) {
  let raw;
  try { raw = fs.readFileSync(file, "utf8"); } catch (e) { return e.code === "ENOENT" ? null : { raw: "", payload: null }; }
  let payload;
  try { payload = JSON.parse(raw); } catch (_) { payload = null; }
  return { raw, payload };
}

function tryCreate(file, payload) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let fd;
  try { fd = fs.openSync(file, "wx"); } catch (e) { if (e.code === "EEXIST") return false; throw e; }
  try { fs.writeSync(fd, JSON.stringify(payload)); } finally { fs.closeSync(fd); }
  return true;
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
}

// gone(payload, startTimeOf) -> true only when the holder is provably not running any more.
function gone(p, startTimeOf) {
  if (!p || !Number.isInteger(p.pid) || p.pid <= 0) return false;
  if (p.host && p.host !== os.hostname()) return false;
  if (!pidAlive(p.pid)) return true;
  if (!Number.isFinite(p.start_ms)) return false;
  const st = startTimeOf(p.pid, { timeoutMs: START_TIME_TIMEOUT_MS });
  return Boolean(st && st.ok && Math.abs(st.ms - p.start_ms) > START_SLACK_MS);
}

function ageOf(file, p) {
  const at = p && Date.parse(p.at);
  if (Number.isFinite(at)) return Math.max(0, Date.now() - at);
  try { return Math.max(0, Date.now() - fs.statSync(file).mtimeMs); } catch (_) { return 0; }
}

function staleMessage(file, p, age) {
  const pid = p && p.pid;
  return `HOLDER_PID=${pid} HOLDER_AGE_MS=${age} LOCK=${file}: a live process has held the PM lock for longer than ${PM_LOCK_STALE_MS} ms. `
    + `Check it with \`Get-Process -Id ${pid}\` (ps -p ${pid}); if it is hung, stop it with \`Stop-Process -Id ${pid}\` (kill ${pid}), `
    + `then remove the lock with \`Remove-Item '${file}'\` (rm '${file}') and retry.`;
}

let depth = 0;

// withPmLock(fn, {waitMs?, startTimeOf?}) -> fn's value; throws PmLockBusy when the lock cannot be taken.
// Re-entrant in one process: a nested call runs fn under the lock already held.
function withPmLock(fn, opts) {
  if (depth > 0) return fn();
  const o = opts || {};
  const waitMs = Number.isFinite(o.waitMs) ? o.waitMs : PM_LOCK_WAIT_MS;
  const startTimeOf = o.startTimeOf || PST.startTimeOf;
  const file = lockPath();
  const mine = { pid: process.pid, start_ms: PST.selfStartTimeMs(), token: crypto.randomUUID(), host: os.hostname(), at: new Date().toISOString() };
  const until = Date.now() + waitMs;
  let judged = null;
  for (;;) {
    if (tryCreate(file, mine)) break;
    const cur = readLock(file);
    if (cur) {
      if (!judged || judged.raw !== cur.raw) judged = { raw: cur.raw, gone: gone(cur.payload, startTimeOf) };
      if (judged.gone) {
        const again = readLock(file);
        if (again && again.raw === cur.raw) { try { fs.rmSync(file, { force: true }); } catch (_) { /* raced */ } }
        continue;
      }
      const age = ageOf(file, cur.payload);
      if (age > PM_LOCK_STALE_MS) throw new PmLockBusy(staleMessage(file, cur.payload, age));
      if (Date.now() >= until) {
        const pid = cur.payload && cur.payload.pid;
        throw new PmLockBusy(`HOLDER_PID=${pid} HOLDER_AGE_MS=${age} LOCK=${file}: another PM command holds the PM lock; retry in a moment.`);
      }
    }
    sleep(Math.min(POLL_MS, Math.max(1, until - Date.now())));
  }
  depth += 1;
  try { return fn(); } finally {
    depth -= 1;
    const cur = readLock(file);
    if (cur && cur.payload && cur.payload.token === mine.token) { try { fs.rmSync(file, { force: true }); } catch (_) { /* gone */ } }
  }
}

module.exports = { withPmLock, PmLockBusy, PM_LOCK_STALE_MS, PM_LOCK_WAIT_MS, lockPath };
