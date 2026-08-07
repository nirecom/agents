// SID-scoped exclusive lock (SSOT, CPR-SSOT) serializing every mutator of a session's
// OFF-clearance bare-token/claim pair. Both the mint transition
// (bin/request-off-clearance) and this shim's claim transition touch the same files,
// so both must hold this SAME lock (keyed off the bare token path) or one can destroy
// or misjudge the other's in-flight write as stale. Uses `wx`, not rename — rename is
// not a mutual-exclusion primitive on Windows (see consume-exact-file.js).
"use strict";

const fs = require("fs");

// Keyed off the bare token path so both participants derive the same lock file.
// ".tmp" suffix lets the existing 24h zombie sweep reap an orphaned lock.
function lockPathFor(tokenPath) {
  return tokenPath + ".mint.lock.tmp";
}

// Synchronous sleep with no dependency and no busy-spin: Atomics.wait on a
// never-notified SharedArrayBuffer blocks this thread for exactly the timeout.
function sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  } catch (_e) {
    const until = Date.now() + ms;
    while (Date.now() < until) { /* spin fallback */ }
  }
}

// Timeout or fault (e.g. unwritable dir) both return null — fail CLOSED: the caller
// must not run its critical section without holding the lock.
function acquireMintLock(tokenPath, waitBudgetMs, pollMs) {
  const lockPath = lockPathFor(tokenPath);
  const deadline = Date.now() + waitBudgetMs;
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, "wx", 0o600);
      return { fd, lockPath };
    } catch (e) {
      if (!e || e.code !== "EEXIST" || Date.now() >= deadline) return null;
      sleepSync(pollMs);
    }
  }
}

// Safe with null (no-op). Callers release in `finally` so a crash mid-critical-section
// can't wedge future acquisitions — zombie-cleanup is the backstop for hard crashes.
function releaseMintLock(lock) {
  if (!lock) return;
  try { fs.closeSync(lock.fd); } catch (_e) {}
  try { fs.unlinkSync(lock.lockPath); } catch (_e) {}
}

module.exports = { lockPathFor, acquireMintLock, releaseMintLock };
