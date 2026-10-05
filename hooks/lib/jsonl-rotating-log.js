"use strict";
// hooks/lib/jsonl-rotating-log.js — lock-guarded, size-rotating JSONL append.
// Owns no file name: each caller passes its own log path (rtk-guard-audit, Jev decisions).

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_MAX_BYTES = 1048576;
const DEFAULT_MAX_ROTATED = 3;
const LOCK_STALE_MS = 2000;
const LOCK_RETRY_MS = 25;
const LOCK_DENIED_MS = 500;
const LOCK_HARD_STALE_MS = 10000;

function resolveLogDir(opts = {}) {
  if (opts.logDir) return opts.logDir;
  const stateDir = process.env.AGENTS_STATE_DIR;
  return stateDir ? path.join(stateDir, "logs") : path.join(os.homedir(), ".agents", "logs");
}

function sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  } catch (_e) {
    const end = Date.now() + ms;
    while (Date.now() < end) { /* SharedArrayBuffer unavailable — spin */ }
  }
}

function newToken() {
  return `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
}

function readToken(p) {
  try { return fs.readFileSync(p, "utf8"); } catch (_e) { return null; }
}

function readMtime(p) {
  try { return fs.statSync(p).mtimeMs; } catch (_e) { return null; }
}

function holderAlive(token) {
  const pid = Number(String(token == null ? "" : token).split(".")[0]);
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  if (pid === process.pid) return true;
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === "EPERM"; }
}

function release(lockPath, token) {
  if (readToken(lockPath) !== token) return; // stolen: the file is a successor's lock
  try { fs.unlinkSync(lockPath); } catch (_e) { /* already removed */ }
}

// A new lock cannot be created while the stale file exists, and only the steal-lock
// holder removes it, so no successor lock is ever touched. Residual: a holder alive
// past LOCK_HARD_STALE_MS can be stolen; PID reuse delays a steal up to that cap.
function stealIfStale(lockPath, staleMs) {
  const token = readToken(lockPath);
  const mtime = readMtime(lockPath);
  if (mtime === null) return true;
  const age = Date.now() - mtime;
  if (age <= staleMs) return false;
  if (holderAlive(token) && age <= LOCK_HARD_STALE_MS) return false;
  const stealPath = `${lockPath}.steal`;
  let fd;
  try { fd = fs.openSync(stealPath, "wx"); }
  catch (e) {
    if (e.code === "EEXIST") {
      const stealMtime = readMtime(stealPath);
      if (stealMtime !== null && Date.now() - stealMtime > LOCK_STALE_MS) {
        try { fs.unlinkSync(stealPath); } catch (_e) { /* already removed */ }
      }
    }
    return false;
  }
  try {
    if (readToken(lockPath) === token && readMtime(lockPath) === mtime) {
      try { fs.unlinkSync(lockPath); } catch (_e) { /* already removed */ }
    }
  } finally {
    try { fs.closeSync(fd); } catch (_e) { /* already closed */ }
    try { fs.unlinkSync(stealPath); } catch (_e) { /* already removed */ }
  }
  return true;
}

// Steal is keyed on lock file mtime (age), never on this caller's wait time.
// Only a hung/crashed holder whose mtime ages past staleMs is stolen; release removes
// the lock only while it still holds this caller's owner token.
function withLock(lockPath, opts, fn) {
  const staleMs = (opts && opts.staleMs) || LOCK_STALE_MS;
  const retryMs = (opts && opts.retryMs) || LOCK_RETRY_MS;
  let deniedSince = 0;
  for (;;) {
    let fd;
    try {
      fd = fs.openSync(lockPath, "wx");
    } catch (e) {
      // Windows reports a lock file whose delete is still pending as EPERM/EACCES,
      // not EEXIST. Bounded, so a directory that is really unwritable still fails.
      if (e.code === "EPERM" || e.code === "EACCES") {
        if (!deniedSince) deniedSince = Date.now();
        if (Date.now() - deniedSince > LOCK_DENIED_MS) throw e;
        sleepSync(retryMs);
        continue;
      }
      if (e.code !== "EEXIST") throw e;
      deniedSince = 0;
      if (!stealIfStale(lockPath, staleMs)) sleepSync(retryMs);
      continue;
    }
    const token = newToken();
    try { fs.writeSync(fd, token); }
    catch (e) {
      try { fs.closeSync(fd); } catch (_e) { /* already closed */ }
      try { fs.unlinkSync(lockPath); } catch (_e) { /* already removed */ }
      throw e;
    }
    try { return fn(); }
    finally {
      try { fs.closeSync(fd); } catch (_e) { /* already closed */ }
      release(lockPath, token);
    }
  }
}

// `log.(N-1) → log.N` … `log → log.1`; the oldest beyond maxRotated is dropped.
function rotate(logPath, maxRotated = DEFAULT_MAX_ROTATED) {
  const oldest = `${logPath}.${maxRotated}`;
  try { fs.unlinkSync(oldest); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
  for (let i = maxRotated - 1; i >= 1; i--) {
    try { fs.renameSync(`${logPath}.${i}`, `${logPath}.${i + 1}`); }
    catch (e) { if (e.code !== "ENOENT") throw e; }
  }
  try { fs.renameSync(logPath, `${logPath}.1`); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
}

function appendJsonlRotating(logPath, obj, opts = {}) {
  const maxBytes = opts.maxBytes || DEFAULT_MAX_BYTES;
  const maxRotated = opts.maxRotated || DEFAULT_MAX_ROTATED;
  try {
    const line = JSON.stringify(obj) + "\n";
    const lineBytes = Buffer.byteLength(line);
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    withLock(opts.lockPath || (logPath + ".lock"), opts, () => {
      try {
        const size = fs.statSync(logPath).size;
        if (size > 0 && size + lineBytes > maxBytes) rotate(logPath, maxRotated);
      } catch (e) { if (e.code !== "ENOENT") throw e; }
      fs.appendFileSync(logPath, line);
    });
    return { ok: true, error: null };
  } catch (e) {
    return { ok: false, error: (e && e.code) || "error" };
  }
}

module.exports = {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_ROTATED,
  LOCK_STALE_MS,
  LOCK_RETRY_MS,
  LOCK_DENIED_MS,
  LOCK_HARD_STALE_MS,
  resolveLogDir,
  holderAlive,
  withLock,
  rotate,
  appendJsonlRotating,
};
