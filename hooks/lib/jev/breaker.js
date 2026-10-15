"use strict";
// hooks/lib/jev/breaker.js — per-session circuit breaker, split by cause so a sick Jev cannot
// add latency to every dispatch and one point's bad answers never block another point.
// Transport scope <sid>/breaker.json (shared by every point): unreachable, timeout, http-error.
// Mapping scope <sid>/breaker-<point>.json: bad-response (an answer set the adapter cannot map).
// Each file = {version, consecutive_failures, open_until_ms, trial_at_ms, last_failure_status};
// a file of another version (or none) reads as closed. no-key and low-confidence never count.
// Once open_until_ms has passed, tryAcquire lets exactly one dispatch try again (half-open)
// by re-opening for TRIAL_MS under the lock and stamping trial_at_ms with its admission time.
// A success given admittedAtMs leaves a scope alone when it opened after that admission and
// the open is not that dispatch's own trial, so a late success cannot clear it.

const fs = require("fs");
const path = require("path");
const { withLock } = require("../jsonl-rotating-log");
const { isValidId, sessionDir, readVersioned, writeJsonAtomic } = require("./state-paths");
const { REGISTRY } = require("./registry");

const BREAKER_VERSION = 2;
const FAILURE_THRESHOLD = 3;
const OPEN_MS = 600000;
// Longer than one probe + query, so a concurrent dispatch cannot start a second trial.
const TRIAL_MS = 30000;
const TRANSPORT = new Set(["unreachable", "timeout", "http-error"]);
const MAPPING = new Set(["bad-response"]);
const COUNTED = new Set([...TRANSPORT, ...MAPPING]);

// A point names a file only when it is a safe id and a registered point (own key).
function validPoint(point) {
  return typeof point === "string" && isValidId(point) && Object.prototype.hasOwnProperty.call(REGISTRY, point);
}

// The transport file, or the mapping file of a valid point (null for an invalid one).
function breakerPath(sid, point) {
  if (point === undefined || point === null) return path.join(sessionDir(sid), "breaker.json");
  return validPoint(point) ? path.join(sessionDir(sid), `breaker-${point}.json`) : null;
}

function scopeFiles(sid, point) {
  const files = [breakerPath(sid)];
  if (validPoint(point)) files.push(breakerPath(sid, point));
  return files;
}

function nowOf(opts) {
  return opts && typeof opts.now === "function" ? opts.now() : Date.now();
}

function readFile(p) {
  const o = (p && readVersioned(p, BREAKER_VERSION)) || {};
  return {
    consecutive_failures: Number.isSafeInteger(o.consecutive_failures) && o.consecutive_failures > 0 ? o.consecutive_failures : 0,
    open_until_ms: typeof o.open_until_ms === "number" && Number.isFinite(o.open_until_ms) ? o.open_until_ms : 0,
    trial_at_ms: typeof o.trial_at_ms === "number" && Number.isFinite(o.trial_at_ms) ? o.trial_at_ms : 0,
    last_failure_status: typeof o.last_failure_status === "string" ? o.last_failure_status : null,
  };
}

// readBreaker(sid): the transport scope; readBreaker(sid, point): that point's mapping scope.
function readBreaker(sid, point) {
  return readFile(breakerPath(sid, point));
}

// isOpen(sid[, point][, opts]): true while any scope the point is gated by is open.
function isOpen(sid, point, opts) {
  if (point && typeof point === "object") return isOpen(sid, undefined, point);
  const now = nowOf(opts);
  return scopeFiles(sid, point).some((p) => readFile(p).open_until_ms > now);
}

// mutate returns the next state, or null to leave the file untouched.
function update(p, mutate) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  withLock(p + ".lock", {}, () => {
    const next = mutate(readFile(p));
    if (next) writeJsonAtomic(p, Object.assign({ version: BREAKER_VERSION }, next));
  });
}

// False while any scope is open; in half-open only the first caller gets true per scope.
// On a lock/IO error the verdict falls back to "no scope open", with nothing written.
function tryAcquire(sid, point, opts) {
  const now = nowOf(opts);
  const files = scopeFiles(sid, point);
  try {
    // Unlocked fast path: an open or closed scope is decided without a write.
    const cur = files.map(readFile);
    if (cur.some((s) => s.open_until_ms > now)) return false;
    if (cur.every((s) => s.consecutive_failures < FAILURE_THRESHOLD)) return true;
    let allowed = true;
    for (const p of files) {
      if (!allowed) break;
      update(p, (s) => {
        if (s.open_until_ms > now) {
          allowed = false;
          return null;
        }
        if (s.consecutive_failures < FAILURE_THRESHOLD) return null;
        return Object.assign({}, s, { open_until_ms: now + TRIAL_MS, trial_at_ms: now });
      });
    }
    return allowed;
  } catch (_e) {
    try {
      return !files.some((p) => readFile(p).open_until_ms > now);
    } catch (_e2) {
      return true;
    }
  }
}

// recordFailure(sid, point, status, opts): transport statuses land in breaker.json; bad-response
// lands in breaker-<point>.json only for a valid point (an invalid one writes nothing).
function recordFailure(sid, point, status, opts) {
  let p = null;
  if (TRANSPORT.has(status)) p = breakerPath(sid);
  else if (MAPPING.has(status) && validPoint(point)) p = breakerPath(sid, point);
  if (!p) return;
  const now = nowOf(opts);
  try {
    update(p, (s) => {
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

// recordSuccess(sid, point, {admittedAtMs}): resets the transport scope and the point's mapping
// scope; without admittedAtMs the reset is unconditional.
function recordSuccess(sid, point, opts) {
  const at = opts && opts.admittedAtMs;
  for (const p of scopeFiles(sid, point)) {
    try {
      update(p, (s) => {
        if (Number.isFinite(at) && s.open_until_ms > at && s.trial_at_ms !== at) return null;
        return { consecutive_failures: 0, open_until_ms: 0, trial_at_ms: 0, last_failure_status: s.last_failure_status };
      });
    } catch (_e) { /* fail-open */ }
  }
}

module.exports = {
  BREAKER_VERSION, FAILURE_THRESHOLD, OPEN_MS, TRIAL_MS, COUNTED,
  breakerPath, readBreaker, isOpen, tryAcquire, recordFailure, recordSuccess,
};
