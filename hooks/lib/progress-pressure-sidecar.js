"use strict";
// hooks/lib/progress-pressure-sidecar.js
// The progress-pressure control file (<WORKFLOW_STATE_DIR>/<sid>.control/progress-pressure.json):
// the progress-nudge counters and cursors. Every writer goes through mergePressure / updatePressure,
// which hold one lock so concurrent hooks never drop each other's keys. A legacy root_sid key is
// read only (hooks/workflow-state/state-ancestry.js); nothing writes it any more.

const { sidecarPath, readSidecar, writeSidecar } = require("./handoff-sidecar");
const { withLock } = require("./jsonl-rotating-log");

const PRESSURE_SUFFIX = "progress-pressure.json";

function readPressure(sid) {
  return readSidecar(sid, PRESSURE_SUFFIX);
}

function lockOpts(opts) {
  return opts && typeof opts.lockWaitMs === "number" ? { maxWaitMs: opts.lockWaitMs } : null;
}

// mergePressure(sid, patch, opts) -> bool — read, merge, write: every writer keeps the other keys.
// The lock serializes concurrent hooks so no writer drops another's keys. Never throws.
// opts.lockWaitMs bounds the lock wait (withLock maxWaitMs); a timeout returns false.
// opts.onlyIf(cur) -> bool makes it a compare-and-set: false under the lock skips the write.
function mergePressure(sid, patch, opts) {
  try {
    const file = sidecarPath(sid, PRESSURE_SUFFIX, { forWrite: true });
    if (file === null) return false;
    return withLock(`${file}.lock`, lockOpts(opts), () => {
      const cur = readPressure(sid) || {};
      if (opts && typeof opts.onlyIf === "function" && opts.onlyIf(cur) !== true) return false;
      return writeSidecar(sid, PRESSURE_SUFFIX, Object.assign({}, cur, patch));
    });
  } catch (_) {
    return false;
  }
}

// updatePressure(sid, fn, opts) -> result | null — fn(cur) -> {patch, result} | null runs under the
// lock, so a read-decide-write cannot race another hook. Null on no-op, lock or write failure.
// A patch whose every value is JSON-equal to the current record skips the write.
// The lock is not reentrant: fn must never call mergePressure or updatePressure. Never throws.
// opts.lockWaitMs bounds the lock wait; a timeout returns null and fn is not run.
function updatePressure(sid, fn, opts) {
  try {
    const file = sidecarPath(sid, PRESSURE_SUFFIX, { forWrite: true });
    if (file === null) return null;
    return withLock(`${file}.lock`, lockOpts(opts), () => {
      const cur = readPressure(sid) || {};
      const out = fn(cur);
      if (!out) return null;
      const patch = out.patch || {};
      const changed = Object.keys(patch).some((k) => JSON.stringify(patch[k]) !== JSON.stringify(cur[k]));
      if (changed && !writeSidecar(sid, PRESSURE_SUFFIX, Object.assign({}, cur, patch))) return null;
      return out.result === undefined ? null : out.result;
    });
  } catch (_) {
    return null;
  }
}

module.exports = { PRESSURE_SUFFIX, readPressure, lockOpts, mergePressure, updatePressure };
