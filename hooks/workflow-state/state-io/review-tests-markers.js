"use strict";
// review_tests control markers (#1361, #2664, #2842): the wrapper's terminal / continuing markers,
// RT-2's unreviewed marker and the wsid pointer. Line 1 = origin (wrapper rc or scope-full:<REASON>),
// line 2 = review-scope fingerprint. The wrapper writes under the workflow session id (wsid); the
// handler holds the CC session id, so every read and clear walks reviewControlSids(ccSid).
// Entrypoint-private to state-io.js. Contracts: skills/_shared/codex-review-loop/exit-codes.md.

const fs = require("fs");
const { assertValidSessionId, SESSION_ID_VALID_RE } = require("./core");

const TERMINAL_MARKER = "test-review-terminal.txt";
const CONTINUING_MARKER = "test-review-continuing.txt";
const UNREVIEWED_MARKER = "test-review-unreviewed.txt";
const WSID_POINTER = "test-review-wsid.txt";

// Trust boundary: single-user local filesystem (NFR); forgeability risk accepted.
function controlMarkerPath(sessionId, name, opts) {
  assertValidSessionId(sessionId);
  const { controlPath } = require("./control-dir");
  return controlPath(sessionId, name, opts);
}

// The ambient workflow session id (cwd / env driven) can name ANOTHER session's plan
// artifacts, and the review-scope fingerprint is shared across sessions, so it is trusted only
// when its context.md records this CC session id (the resolver's own tie-break).
function wsidOwnedBy(wsid, ccSid) {
  try {
    const path = require("path");
    const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
    const text = fs.readFileSync(path.join(getWorkflowPlansDir(), `${wsid}-context.md`), "utf8");
    // Exact `session-id:` line only: a longer id or a quoted mention must not count as ownership.
    return text.split(/\r?\n/).some((line) => line.trim() === `session-id: ${ccSid}`);
  } catch (_) {
    return false;
  }
}

const validSid = (s) => typeof s === "string" && SESSION_ID_VALID_RE.test(s);

// The wsid the wrapper recorded in the CC session's control dir; null when absent or invalid.
function readWsidPointer(ccSid) {
  try {
    const first = (fs.readFileSync(controlMarkerPath(ccSid, WSID_POINTER), "utf8").split("\n")[0] || "").trim();
    return validSid(first) ? first : null;
  } catch (_) {
    return null;
  }
}

// Candidate session ids, in trust order: the wrapper's pointer, an owned ambient wsid, the CC sid.
function reviewControlSids(ccSid) {
  let ambient = null;
  try { ambient = require("../../lib/resolve-workflow-session-id").resolveWorkflowSessionId() || null; } catch (_) {}
  if (ambient === ccSid || !validSid(ambient) || !wsidOwnedBy(ambient, ccSid)) ambient = null;
  const out = [];
  for (const sid of [readWsidPointer(ccSid), ambient, ccSid]) {
    if (validSid(sid) && !out.includes(sid)) out.push(sid);
  }
  return out;
}

// -> { rc, fp, mtimeMs, sid } from the first candidate holding the marker, or null. Only that one
// is judged, so a later candidate can never rescue a refused one (fail-closed).
function readControlMarker(ccSid, name) {
  for (const sid of reviewControlSids(ccSid)) {
    let p;
    try { p = controlMarkerPath(sid, name); } catch (_) { continue; }
    if (!fs.existsSync(p)) continue;
    try {
      const lines = fs.readFileSync(p, "utf8").split("\n");
      return { rc: (lines[0] || "").trim(), fp: (lines[1] || "").trim(), mtimeMs: fs.statSync(p).mtimeMs, sid };
    } catch (_) {
      return null;
    }
  }
  return null;
}

function unlinkMarkers(ccSid, names) {
  for (const sid of reviewControlSids(ccSid)) {
    for (const name of names) {
      try {
        fs.unlinkSync(controlMarkerPath(sid, name));
      } catch (e) {
        // ENOENT (no marker) and any other failure are non-fatal.
        try { require("./control-dir").diagnoseControlMigration(e, "review-tests"); } catch (_) { /* fail-open */ }
      }
    }
  }
}

// RT-2 selected a full review that has not been started yet (the wrapper deletes the marker right
// before it launches the review). Written atomically under the CC session id.
function recordReviewTestsUnreviewed(sessionId, { origin, fingerprint }) {
  const p = controlMarkerPath(sessionId, UNREVIEWED_MARKER, { forWrite: true });
  const tmp = `${p}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, `${origin}\n${fingerprint}\n`);
    fs.renameSync(tmp, p);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* best effort */ }
    throw e;
  }
}

function clearReviewTestsUnreviewed(sessionId) {
  unlinkMarkers(sessionId, [UNREVIEWED_MARKER]);
}

// Accepting the gap ends the review, so the re-invoke guard must no longer fire and no evidence
// may be reused. The wsid pointer is not evidence and stays (the next wrapper run overwrites it).
function clearReviewTestsTerminalMarker(sessionId) {
  unlinkMarkers(sessionId, [TERMINAL_MARKER, CONTINUING_MARKER, UNREVIEWED_MARKER]);
}

module.exports = {
  TERMINAL_MARKER,
  CONTINUING_MARKER,
  UNREVIEWED_MARKER,
  WSID_POINTER,
  controlMarkerPath,
  wsidOwnedBy,
  reviewControlSids,
  readControlMarker,
  recordReviewTestsUnreviewed,
  clearReviewTestsUnreviewed,
  clearReviewTestsTerminalMarker,
};
