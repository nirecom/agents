"use strict";
// Transcript-growth signal of the progress nudge (#2594; was #2218 / #2430 handoff-pressure).
//
// The model updates session-progress.md only when it notices it should. Transcript growth since a
// baseline is measurable without the model's cooperation, so it is the second layer. Only a
// request or a session-progress.md update (hooks/progress-nudge.js) moves the baseline; a hook-side
// handoff write never does, so it cannot silence the check. A risk stamp newer than the
// baseline restarts the timer and halves the limits until the next request — derived, never
// stored. Design: docs/architecture/claude-code/progress-file.md.

const fs = require("fs");
const { toMillis } = require("./control-sidecar");
const { readLastRiskAt } = require("./risk-signal");
const { readPressure, mergePressure } = require("./progress-file");

// Measured defaults (docs/architecture/claude-code/progress-file.md "Omission-check nudge"):
// about one check per hour in a median session.
const INCREMENT_BYTES = 2 * 1024 * 1024;
const ELAPSED_MS = 60 * 60 * 1000;
const RISK_DIVISOR = 2;

// ORed; mutable so a caller can extend the table.
const TRIGGERS = [
  { name: "bytes", fires: (c) => c.bytesSince >= c.limits.bytes },
  { name: "elapsed", fires: (c) => c.msSinceTimer >= c.limits.ms && c.bytesSince > 0 },
];

function statOrNull(p) {
  try {
    if (typeof p !== "string" || p.length === 0) return null;
    return fs.statSync(p);
  } catch (e) {
    return null;
  }
}

// Merge-writes the baseline; every other key of progress-pressure.json is kept.
// opts.lockWaitMs bounds the lock wait; a timeout returns false like any failed write.
// opts.onlyIf(cur) gates the write under the lock (progress-file mergePressure).
function writeBaseline(sid, bytes, at, transcriptPath, opts) {
  return mergePressure(sid, {
    baseline_bytes: bytes,
    baseline_at: new Date(at).toISOString(),
    transcript_path: transcriptPath,
  }, opts);
}

// {bytes, at, transcriptPath} or null when absent / malformed.
function readBaseline(sid) {
  const side = readPressure(sid);
  if (!side) return null;
  const bytes = side.baseline_bytes;
  const at = toMillis(side.baseline_at);
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0 || at === null) return null;
  return { bytes, at, transcriptPath: side.transcript_path };
}

function emptyResult() {
  return { shouldNudge: false, trigger: null, bytesSince: 0, msSinceTimer: 0, riskActive: false };
}

// computePressureSignal({sid, transcriptPath, now, lockWaitMs?}) -> {shouldNudge, trigger, bytesSince,
// msSinceTimer, riskActive}. Never throws: a UserPromptSubmit hook that dies takes the user's
// turn with it. lockWaitMs bounds the baseline write's lock wait.
function computePressureSignal(input) {
  const result = emptyResult();
  try {
    const opts = input || {};
    const sid = opts.sid;
    const writeOpts = typeof opts.lockWaitMs === "number" ? { lockWaitMs: opts.lockWaitMs } : undefined;
    const nowMs = toMillis(opts.now);
    const now = nowMs === null ? Date.now() : nowMs;
    const st = statOrNull(opts.transcriptPath);
    if (!st) return result;
    const size = st.size;
    const tp = opts.transcriptPath;

    const base = readBaseline(sid);
    if (!base) {
      writeBaseline(sid, size, now, tp, writeOpts);
      return result;
    }
    if (size < base.bytes) {
      writeBaseline(sid, size, base.at, tp, writeOpts);
      return result;
    }

    const riskAt = readLastRiskAt(sid);
    const riskActive = riskAt !== null && riskAt > base.at;
    const timerStart = riskActive ? riskAt : base.at;
    const limits = riskActive
      ? { bytes: INCREMENT_BYTES / RISK_DIVISOR, ms: ELAPSED_MS / RISK_DIVISOR }
      : { bytes: INCREMENT_BYTES, ms: ELAPSED_MS };
    const ctx = { bytesSince: size - base.bytes, msSinceTimer: now - timerStart, limits };
    result.bytesSince = ctx.bytesSince;
    result.msSinceTimer = ctx.msSinceTimer;
    result.riskActive = riskActive;

    const fired = TRIGGERS.find((t) => {
      try {
        return t.fires(ctx) === true;
      } catch (_e) {
        return false;
      }
    });
    if (fired) {
      // Advance first: firing without advancing is the every-turn re-fire loop. Compare-and-set
      // on the measured baseline, so of parallel hooks that measured it only one fires.
      const onlyIf = (cur) => cur.baseline_bytes === base.bytes && toMillis(cur.baseline_at) === base.at;
      if (writeBaseline(sid, size, now, tp, Object.assign({}, writeOpts, { onlyIf }))) {
        result.shouldNudge = true;
        result.trigger = fired.name;
      }
      return result;
    }
    if (base.transcriptPath !== tp) writeBaseline(sid, base.bytes, base.at, tp, writeOpts);
    return result;
  } catch (_e) {
    return emptyResult();
  }
}

module.exports = {
  INCREMENT_BYTES,
  ELAPSED_MS,
  RISK_DIVISOR,
  TRIGGERS,
  readBaseline,
  writeBaseline,
  computePressureSignal,
};
