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
// Delete-pending clears as soon as the reader closes its handle; a longer EPERM is not that.
const EPERM_RETRY_MS = 500;

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

function parseLockPayload(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  return parsed;
}

// Identity of the on-disk lock file, or null when it is gone.
function lockSnapshot(lockPath) {
  try {
    const stat = fs.statSync(lockPath);
    const text = fs.readFileSync(lockPath, "utf8");
    return { ino: stat.ino, mtimeMs: stat.mtimeMs, size: stat.size, text };
  } catch (e) {
    return null;
  }
}

function sameSnapshot(a, b) {
  return (
    a !== null && b !== null &&
    a.ino === b.ino && a.mtimeMs === b.mtimeMs && a.size === b.size && a.text === b.text
  );
}

// Returns { reason, snapshot } when the on-disk lock may be taken over, else null.
// `snapshot` is the identity the judgment was made on, so the caller can refuse
// to unlink a lock that another process recreated after the judgment.
function staleReason(lockPath) {
  const snapshot = lockSnapshot(lockPath);
  if (!snapshot) return { reason: "vanished", snapshot: null };
  if (Date.now() - snapshot.mtimeMs > STALE_MS) return { reason: "age", snapshot };

  const payload = parseLockPayload(snapshot.text);
  if (!payload) return null;
  if (typeof payload.host !== "string" || payload.host !== os.hostname()) return null;
  if (typeof payload.pid !== "number" || !Number.isInteger(payload.pid) || payload.pid <= 0) return null;
  try {
    process.kill(payload.pid, 0);
  } catch (e) {
    if (e && e.code === "ESRCH") return { reason: "dead-pid", snapshot };
  }
  return null;
}

function acquire(lockPath, timeoutMs) {
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const deadline = Date.now() + timeoutMs;
  const payload = JSON.stringify({ pid: process.pid, host: os.hostname(), at: new Date().toISOString() });
  let epermDeadline = null;
  for (;;) {
    let fd;
    try {
      fd = fs.openSync(lockPath, "wx");
    } catch (e) {
      // Windows: a lock unlinked while another process still reads it stays delete-pending, and
      // O_EXCL open fails with EPERM until the last handle closes; a persistent EPERM still surfaces.
      if (e && e.code === "EPERM" && process.platform === "win32") {
        if (epermDeadline === null) epermDeadline = Math.min(deadline, Date.now() + EPERM_RETRY_MS);
        if (Date.now() < epermDeadline) {
          sleepSync(backoffMs());
          continue;
        }
      }
      if (!e || e.code !== "EEXIST") throw e;
      fd = null;
    }
    epermDeadline = null;
    if (fd !== null) {
      try {
        fs.writeSync(fd, payload);
      } finally {
        fs.closeSync(fd);
      }
      return;
    }
    const stale = staleReason(lockPath);
    if (stale) {
      // A vanished lock was released by its holder: unlinking would delete a successor's live lock.
      // Residual window: a reclaim between the re-check and unlinkSync; closing it needs an atomic compare-and-unlink fs lacks.
      if (stale.reason !== "vanished" && sameSnapshot(stale.snapshot, lockSnapshot(lockPath))) {
        try {
          fs.unlinkSync(lockPath);
        } catch (e) {
          /* another process reclaimed it first */
        }
      }
    }
    // Checked and backed off on every path: a lock that keeps reading as vanished, or a stale one
    // that will not unlink, must neither spin forever nor burn the CPU until the deadline.
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
