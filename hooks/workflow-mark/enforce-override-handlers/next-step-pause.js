"use strict";
// NEXT_STEP_PAUSE/RESUME handler for enforce-override-handlers (#1607).
// Writes/removes <sid>.next-step-paused, the quiet-layer marker read by
// bin/workflow/next-step and the supervisor/stop hooks.
// Deliberately does NOT call reportSentinel(): pausing quiets re-announcement,
// it is not an enforcement escape hatch.
// Split out of enforce-override-handlers.js to keep that file under the size limit.

const fs = require("fs");
const path = require("path");
const { validateSkipReason } = require("../skip-reason");
const {
  NEXT_STEP_PAUSE_RE_DQ, NEXT_STEP_PAUSE_LOOKSLIKE_RE,
  NEXT_STEP_RESUME_RE_DQ, NEXT_STEP_RESUME_LOOKSLIKE_RE,
} = require("../../lib/sentinel-patterns");
const { getWorkflowDir } = require("../../lib/workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function markerPathFor(sessionId) {
  return path.join(getWorkflowDir(), `${sessionId}.next-step-paused`);
}

// handleNextStepPause(ctx): returns true iff the command was a PAUSE/RESUME
// sentinel (handled or reported as malformed), false otherwise.
function handleNextStepPause(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- NEXT_STEP_PAUSE ---
  const pauseMatch = cmd.match(NEXT_STEP_PAUSE_RE_DQ);
  if (!pauseMatch && NEXT_STEP_PAUSE_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed NEXT_STEP_PAUSE — ` +
        `expected: echo "<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (pauseMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — NEXT_STEP_PAUSE sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — NEXT_STEP_PAUSE sentinel NOT applied.`);
      return true;
    }
    let reasonStored = null;
    const v = validateSkipReason(pauseMatch[1]);
    if (v.ok) {
      reasonStored = v.reason;
    } else {
      pushMessage(`workflow-mark: NEXT_STEP_PAUSE reason rejected — ${v.msg} (pause still applied)`);
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
        `workflow-mark: next-step paused for this session (marker: ${markerPath}). ` +
          `Resume with: echo "<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>"`
      );
    } catch (e) {
      signalFatal(`workflow-mark: failed to write next-step pause marker — ${e.message}. Pause NOT applied.`);
    }
    return true;
  }

  // --- NEXT_STEP_RESUME ---
  const resumeMatch = cmd.match(NEXT_STEP_RESUME_RE_DQ);
  if (!resumeMatch && NEXT_STEP_RESUME_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed NEXT_STEP_RESUME — ` +
        `expected: echo "<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }
  if (resumeMatch) {
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — NEXT_STEP_RESUME sentinel NOT applied.`);
      return true;
    }
    if (!SID_RE.test(sessionId)) {
      signalFatal(`workflow-mark: invalid session_id format — NEXT_STEP_RESUME sentinel NOT applied.`);
      return true;
    }
    const rv = validateSkipReason(resumeMatch[1]);
    if (!rv.ok) {
      pushMessage(`workflow-mark: NEXT_STEP_RESUME reason rejected — ${rv.msg} (resume still applied)`);
    }
    try {
      const markerPath = markerPathFor(sessionId);
      try {
        fs.unlinkSync(markerPath);
        pushMessage(`workflow-mark: next-step resumed (pause marker removed: ${markerPath}).`);
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when the marker is already absent.
      }
    } catch (e) {
      signalFatal(`workflow-mark: failed to clear next-step pause marker — ${e.message}. Resume NOT applied.`);
    }
    return true;
  }

  return false;
}

module.exports = { handleNextStepPause };
