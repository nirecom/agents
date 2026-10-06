"use strict";
// hooks/lib/jev/breaker.js — per-session circuit breaker, so a sick Jev cannot add
// latency to every complexity-judge dispatch. State: <jevStateDir>/<sid>/breaker.json =
// {consecutive_failures, open_until_ms, trial_at_ms, last_failure_status}, epoch-ms absolute times.
// Only outages count (unreachable, timeout, http-error, bad-response — from a probe or a query);
// no-key and low-confidence never do; an unmappable successful response is recorded as
// bad-response by the broker. Once open_until_ms has passed, tryAcquire lets exactly one
// dispatch try again (half-open) by re-opening for TRIAL_MS under the lock and stamping
// trial_at_ms with its admission time; that trial's success resets the count and its failure
// re-opens for OPEN_MS. A success given admittedAtMs is ignored when the breaker opened after
// that admission and the open is not that dispatch's own trial, so a late success cannot clear it.

const fs = require("fs");
const path = require("path");
const { withLock } = require("../jsonl-rotating-log");
const { sessionDir, readJson, writeJsonAtomic } = require("./state-paths");

const FAILURE_THRESHOLD = 3;
const OPEN_MS = 600000;
// Longer than one probe + query, so a concurrent dispatch cannot start a second trial.
const TRIAL_MS = 30000;
const COUNTED = new Set(["unreachable", "timeout", "http-error", "bad-response"]);

function breakerPath(sid) {
  return path.join(sessionDir(sid), "breaker.json");
}

function nowOf(opts) {
  return opts && opts.now ? opts.now() : Date.now();
}

function readBreaker(sid) {
  const o = readJson(breakerPath(sid)) || {};
  return {
    consecutive_failures: Number.isSafeInteger(o.consecutive_failures) && o.consecutive_failures > 0 ? o.consecutive_failures : 0,
    open_until_ms: typeof o.open_until_ms === "number" && Number.isFinite(o.open_until_ms) ? o.open_until_ms : 0,
    trial_at_ms: typeof o.trial_at_ms === "number" && Number.isFinite(o.trial_at_ms) ? o.trial_at_ms : 0,
    last_failure_status: typeof o.last_failure_status === "string" ? o.last_failure_status : null,
  };
}

function isOpen(sid, opts) {
  return readBreaker(sid).open_until_ms > nowOf(opts);
}

// mutate returns the next state, or null to leave the file untouched.
function update(sid, mutate) {
  const p = breakerPath(sid);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  withLock(p + ".lock", {}, () => {
    const next = mutate(readBreaker(sid));
    if (next) writeJsonAtomic(p, next);
  });
}

// False while open; in half-open only the first caller gets true. Fail-open on a lock/IO error.
function tryAcquire(sid, opts) {
  const now = nowOf(opts);
  let allowed = true;
  try {
    // Unlocked fast path: a closed breaker needs no lock (an opening failure sets open_until_ms itself).
    const cur = readBreaker(sid);
    if (cur.consecutive_failures < FAILURE_THRESHOLD && cur.open_until_ms <= now) return true;
    update(sid, (s) => {
      if (s.open_until_ms > now) {
        allowed = false;
        return null;
      }
      if (s.consecutive_failures < FAILURE_THRESHOLD) return null;
      return Object.assign({}, s, { open_until_ms: now + TRIAL_MS, trial_at_ms: now });
    });
  } catch (_e) {
    return !isOpen(sid, opts);
  }
  return allowed;
}

function recordFailure(sid, status, opts) {
  if (!COUNTED.has(status)) return;
  const now = nowOf(opts);
  try {
    update(sid, (s) => {
      const n = s.consecutive_failures + 1;
      const opens = n >= FAILURE_THRESHOLD;
      return {
        consecutive_failures: n,
        open_until_ms: opens ? now + OPEN_MS : s.open_until_ms,
        // A failure's open is never a trial, so the trial's own late success cannot clear it.
        trial_at_ms: opens ? 0 : s.trial_at_ms,
        last_failure_status: status,
      };
    });
  } catch (_e) { /* fail-open: a lost count only delays opening */ }
}

// opts.admittedAtMs: when the succeeding dispatch passed tryAcquire; without it the reset is unconditional.
function recordSuccess(sid, opts) {
  const at = opts && opts.admittedAtMs;
  try {
    update(sid, (s) => {
      if (Number.isFinite(at) && s.open_until_ms > at && s.trial_at_ms !== at) return null;
      return { consecutive_failures: 0, open_until_ms: 0, trial_at_ms: 0, last_failure_status: s.last_failure_status };
    });
  } catch (_e) { /* fail-open */ }
}

module.exports = {
  FAILURE_THRESHOLD, OPEN_MS, TRIAL_MS, COUNTED, breakerPath, readBreaker, isOpen, tryAcquire, recordFailure, recordSuccess,
};
