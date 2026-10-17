"use strict";
// The cheap pre-check of hooks/progress-nudge.js: PostToolUse runs on every tool call (matcher
// ""), so a call that cannot produce a request must leave after a few stats and one small read.
// Bash / Agent / Task (step completes, 4a) and Stop always take the full path.

const fs = require("fs");
const { toMillis } = require("../lib/handoff-sidecar");
const { readPressure } = require("../lib/progress-file");
const { INCREMENT_BYTES, ELAPSED_MS, RISK_DIVISOR } = require("../lib/progress-pressure");

// The halved limits: a live risk can fire there, so the pre-check must not stop below them.
const LIGHT_BYTES = INCREMENT_BYTES / RISK_DIVISOR;
const LIGHT_MS = ELAPSED_MS / RISK_DIVISOR;
const MTIME_TOLERANCE_MS = 2;

function sizeOf(p) {
  try { return fs.statSync(p).size; } catch (_) { return null; }
}

function mtimeOf(p) {
  try { return fs.statSync(p).mtimeMs; } catch (_) { return null; }
}

// needsFullPath(sid, transcriptPath, now) -> bool. Errs toward true (the full path is
// fail-open too); false only when nothing here could fire.
function needsFullPath(sid, transcriptPath, now) {
  try {
    const p = readPressure(sid);
    if (!p) return true;
    if (p.compaction_pending === true || p.burst_pending === true) return true;
    const size = sizeOf(transcriptPath);
    if (size === null) return false;
    const baseBytes = typeof p.baseline_bytes === "number" ? p.baseline_bytes : null;
    if (baseBytes === null || size - baseBytes >= LIGHT_BYTES || size < baseBytes) return true;
    const baseAt = toMillis(p.baseline_at);
    if (baseAt === null || now - baseAt >= LIGHT_MS) return true;
    if (typeof p.progress_path === "string") {
      const m = mtimeOf(p.progress_path);
      const seen = typeof p.progress_seen_mtime === "number" ? p.progress_seen_mtime : null;
      if (m !== null && (seen === null || Math.abs(m - seen) > MTIME_TOLERANCE_MS)) return true;
    }
    return false;
  } catch (_) {
    return true;
  }
}

module.exports = { MTIME_TOLERANCE_MS, needsFullPath };
