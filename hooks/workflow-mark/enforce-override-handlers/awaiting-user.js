"use strict";
// AWAITING_USER/AWAITING_USER_END handler for enforce-override-handlers (#1685).
// Writes/removes <sid>.awaiting-user, the single-turn quiet-layer marker consumed
// on the next Stop by hooks/stop-premature-stop-guard.js via consumeAwaitingUser().
// No TTL (unlike background-work): consume-on-read is the primary clear path, END
// is only the explicit cancel path for a turn that moved on without an answer.
// Deliberately does NOT call reportSentinel(): this quiets re-announcement while
// awaiting a user answer, it is not an enforcement escape hatch.
// Split out of enforce-override-handlers.js to keep that file under the size limit.

const fs = require("fs");
const path = require("path");
const { validateSkipReason } = require("../skip-reason");
const {
  AWAITING_USER_RE_DQ, AWAITING_USER_LOOKSLIKE_RE,
  AWAITING_USER_END_RE_DQ, AWAITING_USER_END_LOOKSLIKE_RE,
} = require("../../lib/sentinel-patterns");
const { getWorkflowDir } = require("../../workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function markerPathFor(sessionId) {
  return path.join(getWorkflowDir(), `${sessionId}.awaiting-user`);
}

// handleAwaitingUser(ctx): returns true iff the command was an
// AWAITING_USER/AWAITING_USER_END sentinel (handled or reported as malformed),
// false otherwise.
function handleAwaitingUser(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- AWAITING_USER (declare) ---
  const startMatch = cmd.match(AWAITING_USER_RE_DQ);
  if (!startMatch && AWAITING_USER_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed AWAITING_USER — ` +
        `expected: echo "<<WORKFLOW_AWAITING_USER: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (startMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — AWAITING_USER sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — AWAITING_USER sentinel NOT applied.`);
      return true;
    }
    let reasonStored = null;
    const v = validateSkipReason(startMatch[1]);
    if (v.ok) {
      reasonStored = v.reason;
    } else {
      pushMessage(`workflow-mark: AWAITING_USER reason rejected — ${v.msg} (declaration still applied)`);
    }
    try {
      const dir = getWorkflowDir();
      fs.mkdirSync(dir, { recursive: true });
      const markerPath = markerPathFor(sessionId);
      const tmp = markerPath + ".tmp";
      fs.writeFileSync(
        tmp,
        JSON.stringify({ reason: reasonStored, set_at: new Date().toISOString() }),
        { mode: 0o600 }
      );
      fs.renameSync(tmp, markerPath);
      pushMessage(
        `workflow-mark: awaiting user input for this session (marker: ${markerPath}). ` +
          `Consumed automatically on the next Stop. Cancel with: echo "<<WORKFLOW_AWAITING_USER_END: {reason}>>"`
      );
    } catch (e) {
      signalFatal(`workflow-mark: failed to write awaiting-user marker — ${e.message}. Declaration NOT applied.`);
    }
    return true;
  }

  // --- AWAITING_USER_END (cancel) ---
  const endMatch = cmd.match(AWAITING_USER_END_RE_DQ);
  if (!endMatch && AWAITING_USER_END_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed AWAITING_USER_END — ` +
        `expected: echo "<<WORKFLOW_AWAITING_USER_END: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (endMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — AWAITING_USER_END sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — AWAITING_USER_END sentinel NOT applied.`);
      return true;
    }
    const rv = validateSkipReason(endMatch[1]);
    if (!rv.ok) {
      pushMessage(`workflow-mark: AWAITING_USER_END reason rejected — ${rv.msg} (cancel still applied)`);
    }
    try {
      const markerPath = markerPathFor(sessionId);
      try {
        fs.unlinkSync(markerPath);
        pushMessage(`workflow-mark: awaiting-user declaration cancelled (marker removed: ${markerPath}).`);
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when the marker is already absent (e.g. already consumed).
      }
    } catch (e) {
      signalFatal(`workflow-mark: failed to clear awaiting-user marker — ${e.message}. Cancel NOT applied.`);
    }
    return true;
  }

  return false;
}

module.exports = { handleAwaitingUser };
