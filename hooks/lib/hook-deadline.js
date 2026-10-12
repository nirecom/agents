"use strict";
// hooks/lib/hook-deadline.js — one shared time budget per hook process (#2221).
// The deadline is anchored at process start (now - uptime), not at the call, so time spent
// loading modules counts against the settings.json timeout. A safety margin is kept back for
// printing the JSON result; every child spawn and repair takes a slice of what is left.

const MIN_SLICE_MS = 100;
const DEFAULT_SAFETY_MARGIN_MS = 700;

function createDeadline({ hookTimeoutMs, safetyMarginMs = DEFAULT_SAFETY_MARGIN_MS, now = Date.now, uptimeSec = process.uptime } = {}) {
  const startedAt = now() - uptimeSec() * 1000;
  const deadlineAt = startedAt + Number(hookTimeoutMs) - safetyMarginMs;
  const remainingMs = () => deadlineAt - now();
  // A slice below MIN_SLICE_MS is not worth spawning for: 0 means "skip it".
  const sliceMs = (cap, reserve = 0) => {
    const v = Math.min(cap, remainingMs() - reserve);
    return v < MIN_SLICE_MS ? 0 : v;
  };
  return { remainingMs, sliceMs, deadlineAt };
}

module.exports = { createDeadline, MIN_SLICE_MS, DEFAULT_SAFETY_MARGIN_MS };
