"use strict";
// Risk signal for the omission-check nudge (#2430): an event after which
// unrecorded working knowledge is most likely to be lost. A stamp newer than the
// nudge baseline restarts its timer and halves its limits (hooks/lib/handoff-pressure.js).
//
// <PLANS_DIR>/<sid>-handoff-risk.json = { last_risk_at, source }. Concurrent
// producers are last-writer-wins: only "a risk happened recently" matters.

const { readSidecar, writeSidecar, toMillis } = require("./handoff-sidecar");

const RISK_SOURCES = Object.freeze([
  "compaction",
  "gate-block",
  "reset-from",
  "supervisor-verdict",
  "supervisor-finding",
  "test-failure",
]);
const RISK_SUFFIX = "handoff-risk.json";

// Unknown source or invalid sid → no-op. Never throws.
function recordRiskSignal(sid, source) {
  try {
    if (RISK_SOURCES.indexOf(source) === -1) return false;
    return writeSidecar(sid, RISK_SUFFIX, { last_risk_at: new Date().toISOString(), source });
  } catch (_e) {
    return false;
  }
}

// Epoch ms of the latest stamp, or null when absent / unreadable. Never throws.
function readLastRiskAt(sid) {
  try {
    const stamp = readSidecar(sid, RISK_SUFFIX);
    return stamp ? toMillis(stamp.last_risk_at) : null;
  } catch (_e) {
    return null;
  }
}

module.exports = { RISK_SOURCES, recordRiskSignal, readLastRiskAt };
