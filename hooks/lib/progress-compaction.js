"use strict";
// The compaction half of the progress nudge (#2594), run by hooks/post-compact.js.
// PostCompact cannot deliver a request reliably, so it only leaves pending state in
// <sid>.control/progress-pressure.json; hooks/progress-nudge.js turns it into one request.
//   - compaction_pending: set by the first compaction since the last 4a / 4c request or
//     session-progress.md update only; later ones follow the (halved) volume threshold.
//   - burst: more than BURST_THRESHOLD compactions inside BURST_WINDOW_MS leave one suggestion
//     for the user, once per session, and one class B auto-record state handoff record.
// BURST_THRESHOLD: in 37 sessions' compaction records (then in handoff.md, 2026-10-16), 30 (81%) peak at
// 7 or fewer per 30 min: docs/architecture/claude-code/progress-file.md "Compaction burst".

const { toMillis } = require("./control-sidecar");
const { updatePressure } = require("./progress-file");

const BURST_WINDOW_MS = 30 * 60 * 1000;
const BURST_THRESHOLD = 7;
const KEEP_COMPACTIONS = 20;
// Bounded well under the 5 s PostCompact hook timeout; on timeout the record is dropped fail-open.
const COMPACTION_LOCK_WAIT_MS = 1000;

// decide(cur, now) -> {patch, result} — the read-decide half, run under the pressure lock.
function decide(cur, now) {
  const prior = (Array.isArray(cur.compactions_at) ? cur.compactions_at : [])
    .map(toMillis).filter((t) => t !== null);
  const marks = [toMillis(cur.last_update_at), toMillis(cur.last_request_at)].filter((t) => t !== null);
  const resetAt = marks.length > 0 ? Math.max(...marks) : null;
  const sinceUpdate = prior.filter((t) => resetAt === null || t > resetAt);
  const patch = {
    compactions_at: prior.concat([now]).slice(-KEEP_COMPACTIONS).map((t) => new Date(t).toISOString()),
  };
  const result = { pending: false, burst: false, inWindow: 0 };
  if (sinceUpdate.length === 0) {
    patch.compaction_pending = true;
    result.pending = true;
  }
  const inWindow = prior.concat([now]).filter((t) => now - t < BURST_WINDOW_MS).length;
  if (inWindow > BURST_THRESHOLD && cur.burst_shown !== true) {
    patch.burst_pending = true;
    patch.burst_shown = true;
    result.burst = true;
    result.inWindow = inWindow;
  }
  return { patch, result };
}

// recordCompaction(sid, nowMs) -> {pending, burst} | null. Never throws. The caller gates
// on the workflow active period.
function recordCompaction(sid, nowMs) {
  try {
    const now = typeof nowMs === "number" ? nowMs : Date.now();
    const r = updatePressure(sid, (cur) => decide(cur, now), { lockWaitMs: COMPACTION_LOCK_WAIT_MS });
    if (r === null) return null;
    if (r.burst) {
      try {
        const { appendAutoRecord } = require("./auto-record");
        appendAutoRecord(sid, {
          cls: "B",
          step: "-",
          key: "compaction-burst",
          summary: `${r.inWindow} compactions in 30 min`,
          pointer: "-",
        }, "compaction");
      } catch (_e) { /* a lost breadcrumb costs nothing but the breadcrumb */ }
    }
    return { pending: r.pending, burst: r.burst };
  } catch (_e) {
    return null;
  }
}

module.exports = { BURST_WINDOW_MS, BURST_THRESHOLD, recordCompaction };
