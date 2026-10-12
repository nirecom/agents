"use strict";
// hooks/postuse-shell-snapshot-repair/session-check.js — when the PostToolUse(Failure) hook
// scans the snapshot dir, and what it remembers (#2221). The first Bash call of a session
// scans once and leaves a per-session marker; afterwards only "Exit code 127" rescans. Only
// snapshots created since this session began count (the transcript's first timestamp), so
// other live sessions' files are left to SessionStart. decide() stays cheap: the repair lib
// is loaded lazily inside runCheck().

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { STATE_SID_RE, getSessionStateDir } = require("../workflow-state/state-io/state-root");

const MAIN_PATH_MAX_REPAIRS = 5;
const FALLBACK_WINDOW_MS = 15 * 60 * 1000;
const TRANSCRIPT_HEAD_BYTES = 64 * 1024;
const LOWER_BOUND_SLACK_MS = 5000;
const MARKER_SUFFIX = ".shell-snapshot-checked";

function validSid(sid) {
  return typeof sid === "string" && STATE_SID_RE.test(sid) && !sid.includes("..");
}

function markerPathFor(sid) {
  return path.join(getSessionStateDir(sid), `${sid}${MARKER_SUFFIX}`);
}

function markerExists(sid) {
  try { return fs.existsSync(markerPathFor(sid)); } catch (_) { return false; }
}

function readMarker(sid) {
  try { return JSON.parse(fs.readFileSync(markerPathFor(sid), "utf8")); } catch (_) { return null; }
}

function writeMarker(sid, data) {
  const p = markerPathFor(sid);
  const tmp = `${p}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(data), { flag: "wx" });
  try { fs.renameSync(tmp, p); } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* ignore */ }
    throw e;
  }
}

function isExit127Failure(input) {
  if (!input || input.hook_event_name !== "PostToolUseFailure" || input.is_interrupt === true) return false;
  if (typeof input.error !== "string") return false;
  return /^Exit code 127$/.test(input.error.split("\n")[0].replace(/\r$/, ""));
}

function decide(input, _opts = {}) {
  const skip = { action: "skip" };
  if (!input || input.tool_name !== "Bash" || !validSid(input.session_id)) return skip;
  const event = input.hook_event_name;
  if (event === "PostToolUse") {
    return markerExists(input.session_id) ? skip : { action: "first", event, failedCommandExit127: false };
  }
  if (event !== "PostToolUseFailure" || input.is_interrupt === true) return skip;
  const is127 = isExit127Failure(input);
  if (!markerExists(input.session_id)) return { action: "first", event, failedCommandExit127: is127 };
  return is127 ? { action: "recheck", event, failedCommandExit127: true } : skip;
}

// Earliest timestamp in the transcript head, minus slack; unreadable -> the last 15 minutes.
function sessionLowerBoundMs(transcriptPath, now = Date.now()) {
  try {
    const { toWindowsPath } = require("../lib/branch-diff");
    const fd = fs.openSync(toWindowsPath(String(transcriptPath)), "r");
    let head;
    try {
      const buf = Buffer.alloc(TRANSCRIPT_HEAD_BYTES);
      head = buf.toString("utf8", 0, fs.readSync(fd, buf, 0, buf.length, 0));
    } finally { fs.closeSync(fd); }
    let min = Infinity;
    for (const m of head.matchAll(/"timestamp"\s*:\s*"([^"]+)"/g)) {
      const t = Date.parse(m[1]);
      if (Number.isFinite(t) && t < min) min = t;
    }
    if (Number.isFinite(min)) return min - LOWER_BOUND_SLACK_MS;
  } catch (_) { /* fall back */ }
  return now - FALLBACK_WINDOW_MS;
}

// What a recheck compares against the marker to avoid repeating the same warning.
function summarize(r) {
  const names = (xs) => xs.slice().sort();
  return {
    repaired: names(r.repaired),
    failed: r.failed.map((f) => `${f.name}:${f.reason}`).sort(),
    unrepairable: names(r.unrepairable),
    missingCore: r.missingCore,
  };
}

function sameWarnings(prev, cur) {
  if (!prev || typeof prev !== "object" || Array.isArray(prev)) return false;
  const pick = (s) => JSON.stringify([s.failed || [], s.unrepairable || [], s.missingCore || 0]);
  return pick(prev) === pick(cur);
}

// Returns the additionalContext text ("" for none). Never throws.
function runCheck(input, decision, { hookTimeoutMs, now = Date.now() } = {}) {
  try {
    const { createDeadline } = require("../lib/hook-deadline");
    const R = require("../lib/shell-snapshot-repair");
    const dl = createDeadline({ hookTimeoutMs });
    const budgetMs = dl.sliceMs(3000, 200);
    const results = R.scanAndRepair({
      homeDir: os.homedir(), platform: process.platform, converterDeps: R.converterFor(dl, budgetMs),
      deadline: dl, budgetMs, maxRepairs: MAIN_PATH_MAX_REPAIRS,
      createdAfterMs: sessionLowerBoundMs(input.transcript_path, now),
    });
    const sid = input.session_id;
    const summary = summarize(results);
    const prev = decision.action === "recheck" ? readMarker(sid) : null;
    let lines = R.formatRepairNotice(results, { trigger: decision.action, failedCommandExit127: decision.failedCommandExit127 });
    if (prev && results.repaired.length === 0 && sameWarnings(prev.results, summary)) lines = [];
    if (results.deferred.length === 0 && results.unscanned === 0) {
      try {
        writeMarker(sid, { version: 1, checked_at: new Date(now).toISOString(), trigger: decision.action, results: summary });
      } catch (_) { /* fail-open: the next call checks again */ }
    }
    return lines.join("\n");
  } catch (_) {
    return "";
  }
}

module.exports = {
  MAIN_PATH_MAX_REPAIRS,
  FALLBACK_WINDOW_MS,
  isExit127Failure,
  decide,
  sessionLowerBoundMs,
  markerPathFor,
  readMarker,
  writeMarker,
  runCheck,
};
