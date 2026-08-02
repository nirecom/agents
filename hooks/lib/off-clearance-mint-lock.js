// hooks/lib/off-clearance-mint-lock.js
// SSOT (CPR-2) for the SID-scoped exclusive lock that serializes every mutator
// of a session's OFF-clearance bare-token / claim pair.
//
// #1780 round-14 HIGH — MINT-LOCK VS SHIM CLAIM-LIFECYCLE RACE.
//
// bin/request-off-clearance (round-13 HIGH-1) already takes this lock around its
// mint + rename + stale-claim-sweep transition, but that only serialized MINT
// against MINT. hooks/supervisor-off-proposal-shim.js's claim-lifecycle
// (validate the bare token -> exclusive-create `<token>.claimed` -> unlink the
// bare token) was a SEPARATE, unsynchronized critical section touching the
// exact same files:
//
//   1. Shim reads bare token A and validates it.
//   2. Concurrently, a NEW mint for the same SID takes the lock, renames its own
//      token over the shared bare-token path (now holding B's bytes), and its
//      stale-claim sweep runs.
//   3. Shim, still acting on the pre-mint read of A, creates `.claimed` (fine —
//      unrelated path) and then unlinks the BARE PATH by name, not by content —
//      which by now holds B's freshly minted, unclaimed token. B's grant is
//      destroyed before its own examiner-approved OFF was ever activated.
//   4. Symmetrically, if the shim's claim write for A lands before B's
//      stale-claim sweep reads it, B's sweep sees a claim whose mint_nonce
//      doesn't match its own (correct per #1780 M-3's rule) and removes it as
//      "stale" — except this claim is not orphaned, it is mid-creation for a
//      grant that IS being activated right now, so the removal destroys the
//      single-use record and the only audit evidence of a legitimate claim.
//
// Both failure modes are the same root cause: two processes mutating the bare
// token / claim pair for one SID without a shared mutex. The mint's lock
// already defines the correct exclusive window for a MINT transition
// (mint + rename + stale-claim-sweep); the fix is for the shim's claim
// transition (re-read the bare token + validate + claim + unlink) to acquire
// the SAME lock, keyed identically off the bare token path, before it touches
// shared state. Two processes holding the SAME name never interleave, whatever
// the OS or order, so this closes both directions of the race at once
// (CPR-5 — symmetric participants, symmetric protection).
//
// WHY `wx` AND NOT `rename`: see hooks/lib/consume-exact-file.js's header for
// the cross-platform measurement — `wx` is a real mutual-exclusion primitive on
// both POSIX and Windows; `rename` is not, on this platform.
"use strict";

const fs = require("fs");

// lockPathFor(tokenPath): the lock is keyed off the BARE TOKEN PATH so both
// participants (the mint in bin/request-off-clearance and the shim's claim
// step) derive the identical lock file for a given SID without any other
// shared state. `.tmp`-suffixed so the existing 24h transient sweep in
// hooks/workflow-state/state-io/zombie-cleanup.js reaps a lock orphaned by a
// hard crash (same convention as the mint lock this replaces).
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

// acquireMintLock(tokenPath, waitBudgetMs, pollMs) -> { fd, lockPath } | null
//
// Returns null on timeout OR on any non-EEXIST fault (unwritable workflow
// dir, etc.) — both are fail-CLOSED for the caller: a critical section that
// could not be entered safely must not run at all.
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

// releaseMintLock(lock): always safe to call, including with null (no-op) —
// callers release in a `finally` so a crash mid-critical-section cannot
// permanently wedge future acquisitions for this SID (the zombie-cleanup
// sweep is the backstop for the hard-crash case, where no `finally` runs).
function releaseMintLock(lock) {
  if (!lock) return;
  try { fs.closeSync(lock.fd); } catch (_e) {}
  try { fs.unlinkSync(lock.lockPath); } catch (_e) {}
}

module.exports = { lockPathFor, acquireMintLock, releaseMintLock };
