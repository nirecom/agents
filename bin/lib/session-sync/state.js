"use strict";
// Run state at <projects>/.git/agents-session-sync-state.json (#2658), written atomically.

const fs = require("node:fs");
const path = require("node:path");

const STATE_NAME = "agents-session-sync-state.json";
const FAILURES = new Set(["failed", "timeout", "offline"]);
const MAX_CONFLICTS = 50;

function blank() {
  return {
    schema: 1, last: null, lastSuccess: { push: null, pull: null }, consecutiveFailures: 0,
    conflicts: [], droppedMarkerLines: 0, uuidMismatch: 0, mtimeRejected: { count: 0, path: null },
    writeDeferred: { count: 0, path: null }, writeBlocked: { count: 0, path: null },
  };
}

function load(gitDir) {
  try {
    const st = Object.assign(blank(), JSON.parse(fs.readFileSync(path.join(gitDir, STATE_NAME), "utf8")));
    if (typeof st.mtimeRejected === "number") st.mtimeRejected = { count: st.mtimeRejected, path: null };
    return st;
  } catch (_) {
    return blank();
  }
}

function save(gitDir, st) {
  const file = path.join(gitDir, STATE_NAME);
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(st, null, 2) + "\n");
  fs.renameSync(tmp, file);
}

// record(gitDir, run) — run: {action, mode, startedAt, result, error, attempts, stats}
function record(gitDir, run) {
  try {
    const st = load(gitDir);
    const endedAt = new Date().toISOString();
    st.last = {
      action: run.action, mode: run.mode || (run.quiet ? "quiet" : "interactive"), startedAt: run.startedAt,
      endedAt, result: run.result, error: run.error || null, attempts: run.attempts || 0,
    };
    if (run.result === "ok" || run.result === "no-change") {
      st.consecutiveFailures = 0;
      st.lastSuccess[run.action === "push" ? "push" : "pull"] = endedAt;
    } else if (FAILURES.has(run.result)) {
      st.consecutiveFailures += 1;
    }
    const s = run.stats || {};
    st.conflicts = st.conflicts.concat(s.conflicts || []).slice(-MAX_CONFLICTS);
    st.droppedMarkerLines += s.droppedMarkerLines || 0;
    st.uuidMismatch += s.uuidMismatch || 0;
    if (s.mtimeRejected && s.mtimeRejected.count) {
      st.mtimeRejected = { count: st.mtimeRejected.count + s.mtimeRejected.count, path: s.mtimeRejected.path };
    }
    if (s.writeDeferred && s.writeDeferred.count) {
      st.writeDeferred = { count: st.writeDeferred.count + s.writeDeferred.count, path: s.writeDeferred.path };
    }
    if (s.writeBlocked && s.writeBlocked.count) {
      st.writeBlocked = { count: st.writeBlocked.count + s.writeBlocked.count, path: s.writeBlocked.path };
    }
    save(gitDir, st);
    return st;
  } catch (_) {
    return null;
  }
}

function newStats() {
  return {
    conflicts: [], droppedMarkerLines: 0, uuidMismatch: 0, mtimeRejected: { count: 0, path: null },
    writeDeferred: { count: 0, path: null }, writeBlocked: { count: 0, path: null },
  };
}

module.exports = { STATE_NAME, load, save, record, newStats };
