"use strict";
// Objective proxy for "this session is about to lose its working context".
//
// The self-report rule in rules/handoff-emergency-flush.md can only fire when
// the model notices the pressure itself, which is exactly what a model deep in
// a long task does not do. Transcript growth since the last handoff write is
// measurable without the model's cooperation, so it is the second detection
// layer.

const fs = require("fs");

// An Accepted Tradeoff, not a measured compaction trigger: large enough that a
// routine turn never trips it, small enough to still leave room to write.
const PRESSURE_BYTES = 300 * 1024;

function statOrNull(p) {
  try {
    if (typeof p !== "string" || p.length === 0) return null;
    return fs.statSync(p);
  } catch (e) {
    return null;
  }
}

function toMillis(value) {
  if (value === undefined || value === null) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Date.parse(String(value));
  return Number.isNaN(parsed) ? null : parsed;
}

// Returns {shouldNudge, bytes, thresholdBytes, flushedAt}. Never throws: a
// UserPromptSubmit hook that dies takes the user's turn with it.
function computePressureSignal(input) {
  const opts = input || {};
  const st = statOrNull(opts.transcriptPath);
  const bytes = st ? st.size : 0;
  const flushedAt = toMillis(opts.handoffMtime);
  let shouldNudge = st !== null && bytes > PRESSURE_BYTES;
  // A handoff written after the transcript last grew has already flushed the
  // accumulated bytes; re-nudging every turn would train the model to ignore it.
  if (shouldNudge && flushedAt !== null && flushedAt >= st.mtimeMs) shouldNudge = false;
  return { shouldNudge, bytes, thresholdBytes: PRESSURE_BYTES, flushedAt };
}

module.exports = { PRESSURE_BYTES, computePressureSignal };
