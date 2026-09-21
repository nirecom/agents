"use strict";
// hooks/lib/rtk-guard-audit.js — JSONL guard-reject log. Size-rotating, fail-open.

const fs = require("fs");
const os = require("os");
const path = require("path");

const LOG_FORMAT_VERSION = 1;
const MAX_BYTES = 1048576;
const MAX_ROTATED = 3;
const LOCK_STALE_MS = 2000;
const LOCK_RETRY_MS = 25;

function resolveLogPath(opts = {}) {
  if (opts.logPath) return opts.logPath;
  const stateDir = process.env.AGENTS_STATE_DIR;
  const base = stateDir
    ? path.join(stateDir, "logs")
    : path.join(os.homedir(), ".agents", "logs");
  return path.join(base, "rtk-guard-audit.log");
}

function sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  } catch (_e) {
    const end = Date.now() + ms;
    while (Date.now() < end) { /* SharedArrayBuffer unavailable — spin */ }
  }
}

// Steal is keyed on lock file mtime (age), never on this caller's wait time.
// Only a hung/crashed holder whose mtime ages past LOCK_STALE_MS is stolen.
function withLock(lockPath, opts, fn) {
  for (;;) {
    let fd;
    try {
      fd = fs.openSync(lockPath, "wx"); // atomic exclusive create (Windows/POSIX)
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let held = 0;
      try { held = Date.now() - fs.statSync(lockPath).mtimeMs; }
      catch (_e) { continue; } // lock vanished — retry acquisition
      if (held > LOCK_STALE_MS) {
        try { fs.unlinkSync(lockPath); } catch (_e) { /* someone else stole it */ }
        continue;
      }
      sleepSync(LOCK_RETRY_MS);
      continue;
    }
    try { fn(); }
    finally {
      try { fs.closeSync(fd); } catch (_e) { /* already closed */ }
      try { fs.unlinkSync(lockPath); } catch (_e) { /* already removed */ }
    }
    return;
  }
}

// `log.(N-1) → log.N` … `log → log.1`; the oldest beyond MAX_ROTATED is dropped.
function rotate(logPath) {
  const oldest = `${logPath}.${MAX_ROTATED}`;
  try { fs.unlinkSync(oldest); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
  for (let i = MAX_ROTATED - 1; i >= 1; i--) {
    try { fs.renameSync(`${logPath}.${i}`, `${logPath}.${i + 1}`); }
    catch (e) { if (e.code !== "ENOENT") throw e; }
  }
  try { fs.renameSync(logPath, `${logPath}.1`); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
}

function recordGuardReject(name, cmd, opts = {}) {
  const ts = new Date(opts.now ? opts.now() : Date.now()).toISOString();
  const line = JSON.stringify({
    v: LOG_FORMAT_VERSION,
    ts,
    guard: name,
    action: "reject",
    command: cmd,
  }) + "\n";
  const logPath = resolveLogPath(opts);
  const lockPath = opts.lockPath || (logPath + ".lock");
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    withLock(lockPath, opts, () => {
      try {
        const size = fs.statSync(logPath).size;
        if (size + line.length > MAX_BYTES) rotate(logPath);
      } catch (e) { if (e.code !== "ENOENT") throw e; }
      fs.appendFileSync(logPath, line); // append stays inside the lock
    });
  } catch (_e) { /* fail-open: audit failure must not reach the hook */ }
}

module.exports = {
  recordGuardReject,
  rotate,
  resolveLogPath,
  LOG_FORMAT_VERSION,
  MAX_BYTES,
  MAX_ROTATED,
  LOCK_STALE_MS,
  LOCK_RETRY_MS,
};
