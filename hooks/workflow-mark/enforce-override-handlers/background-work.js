"use strict";
// BACKGROUND_WORK_START/END handler for enforce-override-handlers (#1665).
// Writes/removes <sid>.background-work, the TTL-based quiet-layer marker read by
// bin/workflow/next-step and the C4 stop guard.
// Deliberately does NOT call reportSentinel(): this quiets re-announcement while
// background work is in flight, it is not an enforcement escape hatch.
// Split out of enforce-override-handlers.js to keep that file under the size limit.

const fs = require("fs");
const path = require("path");
const { validateSkipReason } = require("../skip-reason");
const {
  BACKGROUND_WORK_START_RE_DQ, BACKGROUND_WORK_START_LOOKSLIKE_RE,
  BACKGROUND_WORK_END_RE_DQ, BACKGROUND_WORK_END_LOOKSLIKE_RE,
} = require("../../lib/sentinel-patterns");
const { getWorkflowDir } = require("../../workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const BACKGROUND_WORK_TTL_MS = 4 * 60 * 60 * 1000;

function markerPathFor(sessionId) {
  return path.join(getWorkflowDir(), `${sessionId}.background-work`);
}

// handleBackgroundWork(ctx): returns true iff the command was a START/END
// sentinel (handled or reported as malformed), false otherwise.
function handleBackgroundWork(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- BACKGROUND_WORK_START ---
  const startMatch = cmd.match(BACKGROUND_WORK_START_RE_DQ);
  if (!startMatch && BACKGROUND_WORK_START_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed BACKGROUND_WORK_START — ` +
        `expected: echo "<<WORKFLOW_BACKGROUND_WORK_START: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (startMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — BACKGROUND_WORK_START sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — BACKGROUND_WORK_START sentinel NOT applied.`);
      return true;
    }
    let reasonStored = null;
    const v = validateSkipReason(startMatch[1]);
    if (v.ok) {
      reasonStored = v.reason;
    } else {
      pushMessage(`workflow-mark: BACKGROUND_WORK_START reason rejected — ${v.msg} (start still applied)`);
    }
    try {
      const dir = getWorkflowDir();
      fs.mkdirSync(dir, { recursive: true });
      const markerPath = markerPathFor(sessionId);
      const tmp = markerPath + ".tmp";
      const setAt = new Date();
      const expiresAt = new Date(setAt.getTime() + BACKGROUND_WORK_TTL_MS);
      fs.writeFileSync(
        tmp,
        JSON.stringify({
          reason: reasonStored,
          set_at: setAt.toISOString(),
          expires_at: expiresAt.toISOString(),
        }),
        { mode: 0o600 }
      );
      fs.renameSync(tmp, markerPath);
      pushMessage(
        `workflow-mark: background work in flight for this session (marker: ${markerPath}). ` +
          `End with: echo "<<WORKFLOW_BACKGROUND_WORK_END: {reason}>>"`
      );
    } catch (e) {
      signalFatal(`workflow-mark: failed to write background-work marker — ${e.message}. Start NOT applied.`);
    }
    return true;
  }

  // --- BACKGROUND_WORK_END ---
  const endMatch = cmd.match(BACKGROUND_WORK_END_RE_DQ);
  if (!endMatch && BACKGROUND_WORK_END_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed BACKGROUND_WORK_END — ` +
        `expected: echo "<<WORKFLOW_BACKGROUND_WORK_END: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (endMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — BACKGROUND_WORK_END sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — BACKGROUND_WORK_END sentinel NOT applied.`);
      return true;
    }
    const rv = validateSkipReason(endMatch[1]);
    if (!rv.ok) {
      pushMessage(`workflow-mark: BACKGROUND_WORK_END reason rejected — ${rv.msg} (end still applied)`);
    }
    try {
      const markerPath = markerPathFor(sessionId);
      try {
        fs.unlinkSync(markerPath);
        pushMessage(`workflow-mark: background work ended (marker removed: ${markerPath}).`);
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when the marker is already absent.
      }
    } catch (e) {
      signalFatal(`workflow-mark: failed to clear background-work marker — ${e.message}. End NOT applied.`);
    }
    return true;
  }

  return false;
}

module.exports = { handleBackgroundWork };
