"use strict";
// Omission-check nudge signal (#2218, reshaped by #2430).
//
// The self-report rule in rules/handoff-emergency-flush.md can only fire when
// the model notices the pressure itself. Transcript growth since a baseline is
// measurable without the model's cooperation, so it is the second detection
// layer. Only a nudge or a main-session flush (the flush mark) moves the
// baseline; a hook-side handoff write never does, so it cannot silence the
// check. A risk stamp newer than the baseline restarts the timer and halves the
// limits until the next nudge or flush — derived, never stored.

const fs = require("fs");
const { readSidecar, writeSidecar, toMillis } = require("./handoff-sidecar");
const { readLastRiskAt } = require("./handoff-risk-signal");

// Measured defaults (docs/architecture/claude-code/handoff-artifact.md
// "Omission-check nudge"): about one check per hour in a median session.
const INCREMENT_BYTES = 2 * 1024 * 1024;
const ELAPSED_MS = 60 * 60 * 1000;
const RISK_DIVISOR = 2;

const PRESSURE_SUFFIX = "handoff-pressure.json"; // writer: the nudge hook only
const FLUSH_MARK_SUFFIX = "handoff-flush-mark.json"; // writer: handoff-append only

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

// transcript_path is the file the nudge measured: one sid can own transcripts
// in several project dirs, and the flush mark must be sized from this one.
function writeBaseline(sid, bytes, at, transcriptPath) {
  return writeSidecar(sid, PRESSURE_SUFFIX, {
    baseline_bytes: bytes,
    baseline_at: new Date(at).toISOString(),
    transcript_path: transcriptPath,
  });
}

function readBaseline(sid) {
  const side = readSidecar(sid, PRESSURE_SUFFIX);
  if (!side) return null;
  const bytes = side.baseline_bytes;
  const at = toMillis(side.baseline_at);
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0 || at === null) return null;
  return { bytes, at, transcriptPath: side.transcript_path };
}

// The transcript the nudge last measured for this sid, or null when none is
// recorded or it can no longer be stat'ed. Never throws.
function measuredTranscriptPath(sid) {
  try {
    const side = readSidecar(sid, PRESSURE_SUFFIX);
    const p = side ? side.transcript_path : null;
    return statOrNull(p) ? p : null;
  } catch (_e) {
    return null;
  }
}

// Records {bytes, at} after a successful flush; bytes is null when the
// transcript cannot be stat'ed. Never throws; invalid sid writes nothing.
function recordFlushMark(sid, transcriptPath, at) {
  try {
    const st = statOrNull(transcriptPath);
    const atMs = toMillis(at);
    const stamp = new Date(atMs === null ? Date.now() : atMs).toISOString();
    return writeSidecar(sid, FLUSH_MARK_SUFFIX, { bytes: st ? st.size : null, at: stamp });
  } catch (_e) {
    return false;
  }
}

// Returns {shouldNudge, trigger, bytesSince, msSinceTimer, riskActive}. Never
// throws: a UserPromptSubmit hook that dies takes the user's turn with it.
function computePressureSignal(input) {
  const result = { shouldNudge: false, trigger: null, bytesSince: 0, msSinceTimer: 0, riskActive: false };
  try {
    const opts = input || {};
    const sid = opts.sid;
    const nowMs = toMillis(opts.now);
    const now = nowMs === null ? Date.now() : nowMs;
    const st = statOrNull(opts.transcriptPath);
    if (!st) return result;
    const size = st.size;
    const tp = opts.transcriptPath;

    let base = readBaseline(sid);
    if (!base) {
      writeBaseline(sid, size, now, tp);
      return result;
    }
    // Rewrite when the flush mark moved the baseline or the measured path changed.
    let dirty = base.transcriptPath !== tp;
    const mark = readSidecar(sid, FLUSH_MARK_SUFFIX);
    const markAt = mark ? toMillis(mark.at) : null;
    if (markAt !== null && markAt > base.at) {
      // Growth written after the flush still counts toward the next nudge.
      if (typeof mark.bytes === "number" && Number.isFinite(mark.bytes) && mark.bytes <= size) {
        base = { bytes: mark.bytes, at: markAt };
        dirty = true;
      } else {
        writeBaseline(sid, size, markAt, tp);
        return result;
      }
    }
    if (size < base.bytes) {
      writeBaseline(sid, size, base.at, tp);
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
      // Advance first: firing without advancing is the every-turn re-fire loop.
      if (writeBaseline(sid, size, now, tp)) {
        result.shouldNudge = true;
        result.trigger = fired.name;
      }
      return result;
    }
    if (dirty) writeBaseline(sid, base.bytes, base.at, tp);
    return result;
  } catch (_e) {
    return { shouldNudge: false, trigger: null, bytesSince: 0, msSinceTimer: 0, riskActive: false };
  }
}

module.exports = {
  INCREMENT_BYTES,
  ELAPSED_MS,
  RISK_DIVISOR,
  TRIGGERS,
  measuredTranscriptPath,
  recordFlushMark,
  computePressureSignal,
};
