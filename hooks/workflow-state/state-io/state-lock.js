"use strict";

// Advisory cross-process lock for a single workflow state file (#1733).
//
// The lock is an O_EXCL-created sidecar file `<statefile>.lock` holding
// `{ pid, host, at }`. Every mutation of the state file must happen inside
// `withStateLock`, so a reader/writer pair from two processes can never
// interleave a read-modify-write.

const fs = require("fs");
const os = require("os");
const path = require("path");

// A lock older than this is considered abandoned regardless of what its
// payload says. PID reuse means `process.kill(pid, 0)` can report "live" for a
// completely unrelated process that happens to have inherited the recorded pid
// after 30s, so pid liveness alone can never expire a lock — the mtime bound is
// the backstop that guarantees forward progress.
const STALE_MS = 30000;
const DEFAULT_TIMEOUT_MS = 3000;
const MIN_BACKOFF_MS = 5;
const MAX_BACKOFF_MS = 25;
const MAX_REACQUIRE = 2;

class StateLockTimeoutError extends Error {
  constructor(message) {
    super(message);
    this.name = "StateLockTimeoutError";
  }
}

// Per-process re-entrancy: resolved lock path -> depth counter. A nested
// `withStateLock` for the same state file reuses the already-held lock instead
// of self-deadlocking on its own O_EXCL file.
const heldLocks = new Map();

function sleepSync(ms) {
  const view = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(view, 0, 0, ms);
}

function backoffMs() {
  return MIN_BACKOFF_MS + Math.floor(Math.random() * (MAX_BACKOFF_MS - MIN_BACKOFF_MS));
}

function lockPathFor(sessionId) {
  // Lazy require: core.js depends on this module for writeState.
  const { getStatePath } = require("./core");
  return getStatePath(sessionId) + ".lock";
}

function readLockPayload(lockPath) {
  let text;
  try {
    text = fs.readFileSync(lockPath, "utf8");
  } catch (e) {
    return null;
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  return parsed;
}

// Returns a reason string when the on-disk lock may be taken over, else null.
function staleReason(lockPath) {
  let stat;
  try {
    stat = fs.statSync(lockPath);
  } catch (e) {
    return "vanished";
  }
  if (Date.now() - stat.mtimeMs > STALE_MS) return "age";

  const payload = readLockPayload(lockPath);
  if (!payload) return null;
  if (typeof payload.host !== "string" || payload.host !== os.hostname()) return null;
  if (typeof payload.pid !== "number" || !Number.isInteger(payload.pid) || payload.pid <= 0) return null;
  try {
    process.kill(payload.pid, 0);
  } catch (e) {
    if (e && e.code === "ESRCH") return "dead-pid";
  }
  return null;
}

function acquire(lockPath, timeoutMs) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  const payload = JSON.stringify({ pid: process.pid, host: os.hostname(), at: new Date().toISOString() });
  for (;;) {
    let fd;
    try {
      fd = fs.openSync(lockPath, "wx");
    } catch (e) {
      if (!e || e.code !== "EEXIST") throw e;
      fd = null;
    }
    if (fd !== null) {
      try {
        fs.writeSync(fd, payload);
      } finally {
        fs.closeSync(fd);
      }
      return;
    }
    if (staleReason(lockPath)) {
      try {
        fs.unlinkSync(lockPath);
      } catch (e) {
        /* another process reclaimed it first */
      }
      continue;
    }
    if (Date.now() >= deadline) {
      throw new StateLockTimeoutError(
        `timed out after ${timeoutMs}ms waiting for workflow state lock: ${lockPath}`
      );
    }
    sleepSync(backoffMs());
  }
}

// withStateLock(sessionId, fn, opts) -> fn's return value.
// The lock is always released, including when `fn` throws.
function withStateLock(sessionId, fn, opts = {}) {
  const lockPath = lockPathFor(sessionId);
  const depth = heldLocks.get(lockPath);
  if (depth !== undefined) {
    heldLocks.set(lockPath, depth + 1);
    try {
      return fn();
    } finally {
      const next = heldLocks.get(lockPath) - 1;
      if (next <= 0) heldLocks.delete(lockPath);
      else heldLocks.set(lockPath, next);
    }
  }

  const timeoutMs =
    typeof opts.timeoutMs === "number" && opts.timeoutMs > 0 ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;
  let held = lockPath;
  acquire(held, timeoutMs);
  // --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
  // deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
  // A relocation that committed while we waited moves the state: re-take the lock at the new path.
  for (let retry = 0; ; retry++) {
    const now = lockPathFor(sessionId);
    if (now === held) break;
    releaseLockFile(held);
    if (retry >= MAX_REACQUIRE) {
      throw new StateLockTimeoutError(`workflow state lock moved more than ${MAX_REACQUIRE} times: ${now}`);
    }
    held = now;
    acquire(held, timeoutMs);
  }
  // --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---
  heldLocks.set(held, 1);
  try {
    return fn();
  } finally {
    heldLocks.delete(held);
    releaseLockFile(held);
  }
}

function releaseLockFile(lockPath) {
  try {
    fs.unlinkSync(lockPath);
  } catch (e) {
    /* already reclaimed */
  }
}

// --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
// deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
// withStateLockAt(lockPath, fn, opts): the relocation takes the new-root lock before its
// commit makes lockPathFor() resolve there. Registered for re-entrancy like withStateLock.
function withStateLockAt(lockPath, fn, opts = {}) {
  const timeoutMs =
    typeof opts.timeoutMs === "number" && opts.timeoutMs > 0 ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;
  if (heldLocks.has(lockPath)) throw new Error(`state lock already held: ${lockPath}`);
  acquire(lockPath, timeoutMs);
  heldLocks.set(lockPath, 1);
  try {
    return fn();
  } finally {
    heldLocks.delete(lockPath);
    releaseLockFile(lockPath);
  }
}
// --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---

module.exports = { withStateLock, withStateLockAt, StateLockTimeoutError, STALE_MS };
