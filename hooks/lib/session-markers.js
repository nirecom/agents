// hooks/lib/session-markers.js — session-marker readers (SSOT for workflow-off and worktree-off)
"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("../workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// isWorkflowOff(sid): returns true iff <workflowDir>/<sid>.workflow-off exists
// and sid matches /^[A-Za-z0-9_-]+$/. Fail-closed: any error → false.
function isWorkflowOff(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const dir = getWorkflowDir();
    const markerPath = path.join(dir, sid + ".workflow-off");
    return fs.existsSync(markerPath);
  } catch (_e) {
    return false;
  }
}

// workflowOffNoticeText(hookName, sid): returns a human-readable string about
// the workflow-off override. NEVER throws — falls back to `<unresolved: ...>`
// if getWorkflowDir() or path resolution throws.
function workflowOffNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".workflow-off");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] ENFORCE_WORKFLOW is OFF for this session (sid=" + sid + "). " +
    "Marker: " + markerPath + ". " +
    "Restore with: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>\""
  );
}

// isWorktreeOff(sid): returns true iff <workflowDir>/<sid>.worktree-off exists.
// Fail-closed: any error → false.
function isWorktreeOff(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const dir = getWorkflowDir();
    const markerPath = path.join(dir, sid + ".worktree-off");
    return fs.existsSync(markerPath);
  } catch (_e) {
    return false;
  }
}

// worktreeOffNoticeText(hookName, sid): returns a human-readable string about
// the worktree-off session override. NEVER throws — falls back to
// `<unresolved: ...>` if getWorkflowDir() or path resolution throws.
function worktreeOffNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".worktree-off");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] session override active (marker: " + markerPath + "). " +
    "Delete the marker to restore enforcement."
  );
}

// isIssueCloseVerified(sid): returns true iff <workflowDir>/<sid>.issue-close-verified
// exists. Fail-closed: any error → false.
function isIssueCloseVerified(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const dir = getWorkflowDir();
    const markerPath = path.join(dir, sid + ".issue-close-verified");
    return fs.existsSync(markerPath);
  } catch (_e) {
    return false;
  }
}

// issueCloseVerifiedNoticeText(hookName, sid): returns a human-readable string
// about the issue-close-verified override. NEVER throws.
function issueCloseVerifiedNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".issue-close-verified");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] ISSUE_CLOSE_VERIFIED is active for this session (sid=" + sid + "). " +
    "Marker: " + markerPath + ". " +
    "End with: echo \"<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: {reason}>>\""
  );
}

// isNextStepPaused(sid): returns true iff <workflowDir>/<sid>.next-step-paused
// exists (#1607 quiet layer). Fail-closed: any error → false.
function isNextStepPaused(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const dir = getWorkflowDir();
    const markerPath = path.join(dir, sid + ".next-step-paused");
    return fs.existsSync(markerPath);
  } catch (_e) {
    return false;
  }
}

// nextStepPausedNoticeText(hookName, sid): human-readable string about the
// next-step pause. NEVER throws.
function nextStepPausedNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".next-step-paused");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] next-step is paused for this session (sid=" + sid + "). " +
    "Marker: " + markerPath + ". " +
    "Resume with: echo \"<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>\""
  );
}

// readOffClearance(sid): READ LAYER ONLY for <workflowDir>/<sid>.off-clearance (#1608).
// Absent / unreadable / unparseable → null. Validity (expiry, target, reason-binding)
// is NOT decided here — evaluateOffClearance() is the single source of truth for that.
// Callers that must distinguish ENOENT from other I/O or parse failures (the shim's
// fail-CLOSED contract) read the file directly instead.
function readOffClearance(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return null;
    const tokenPath = path.join(getWorkflowDir(), sid + ".off-clearance");
    const token = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
    if (!token || typeof token !== "object") return null;
    return token;
  } catch (_e) {
    return null;
  }
}

// evaluateOffClearance(token, target, reasonText): SSOT for OFF-clearance validity.
// A token is valid iff it is unexpired, its target matches, and its category appears
// inside the emitted sentinel reason (reason-binding, substring match).
// Fail-CLOSED on malformed expiry metadata: a missing, non-string, or unparseable
// expires_at is treated as EXPIRED (a token that cannot prove it is live is not live).
function evaluateOffClearance(token, target, reasonText) {
  if (!token || typeof token !== "object") return false;
  if (typeof token.expires_at !== "string") return false;
  const expiresAt = Date.parse(token.expires_at);
  if (Number.isNaN(expiresAt) || expiresAt <= Date.now()) return false;
  if (typeof token.target !== "string" || token.target !== target) return false;
  if (typeof token.category !== "string" || token.category.length === 0) return false;
  if (typeof reasonText !== "string") return false;
  return reasonText.includes(token.category);
}

// isOffClearanceValid(sid, target, reasonText): true iff a readable token for sid
// satisfies evaluateOffClearance(). Fail-closed: any error → false.
function isOffClearanceValid(sid, target, reasonText) {
  try {
    return evaluateOffClearance(readOffClearance(sid), target, reasonText);
  } catch (_e) {
    return false;
  }
}

// isBackgroundWorkInFlight(sid): true iff <workflowDir>/<sid>.background-work
// exists AND its expires_at is in the future. Fail-CLOSED (same shape as
// evaluateOffClearance): absent / unreadable / non-JSON / expires_at missing,
// non-string, unparseable, or in the past → false. A forgotten END must not
// silence C4 forever.
function isBackgroundWorkInFlight(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const markerPath = path.join(getWorkflowDir(), sid + ".background-work");
    const marker = JSON.parse(fs.readFileSync(markerPath, "utf8"));
    if (!marker || typeof marker !== "object") return false;
    if (typeof marker.expires_at !== "string") return false;
    const expiresAt = Date.parse(marker.expires_at);
    if (Number.isNaN(expiresAt) || expiresAt <= Date.now()) return false;
    return true;
  } catch (_e) {
    return false;
  }
}

// backgroundWorkNoticeText(hookName, sid): human-readable string about the
// background-work marker. NEVER throws.
function backgroundWorkNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".background-work");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] background work is in flight for this session (sid=" + sid + "). " +
    "Marker: " + markerPath + ". " +
    "End with: echo \"<<WORKFLOW_BACKGROUND_WORK_END: {reason}>>\""
  );
}

// isAwaitingUser(sid): true iff <workflowDir>/<sid>.awaiting-user exists.
// No TTL — this is a single-turn declaration consumed by consumeAwaitingUser()
// on the next Stop, not a duration-bound override. Fail-closed: any error → false.
function isAwaitingUser(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return false;
    const markerPath = path.join(getWorkflowDir(), sid + ".awaiting-user");
    return fs.existsSync(markerPath);
  } catch (_e) {
    return false;
  }
}

// consumeAwaitingUser(sid): best-effort delete of the .awaiting-user marker
// (consume-on-read, same pattern as hooks/lib/turn-marker.js's
// readAndDeleteTurnMarkers). Placed here rather than in a write-only module
// because it is the sole deletion function among this file's marker readers —
// the "awaiting user" fact is single-turn, so C4 must consume it the moment it
// acts on it, not merely read it. Never throws: ENOENT and any other error are
// both swallowed, since a failed cleanup must not block the Stop hook.
function consumeAwaitingUser(sid) {
  try {
    if (typeof sid !== "string" || !SID_RE.test(sid)) return;
    const markerPath = path.join(getWorkflowDir(), sid + ".awaiting-user");
    fs.unlinkSync(markerPath);
  } catch (_e) {
    // best-effort: ENOENT (already consumed/absent) and any other I/O error are ignored.
  }
}

// awaitingUserNoticeText(hookName, sid): human-readable string about the
// awaiting-user marker. NEVER throws.
function awaitingUserNoticeText(hookName, sid) {
  let markerPath;
  try {
    const dir = getWorkflowDir();
    markerPath = path.join(dir, sid + ".awaiting-user");
  } catch (e) {
    markerPath = "<unresolved: " + (e && e.message ? e.message : String(e)) + ">";
  }
  return (
    "[" + hookName + "] awaiting user input for this session (sid=" + sid + "). " +
    "Marker: " + markerPath + ". Consumed automatically on the next Stop. " +
    "Cancel with: echo \"<<WORKFLOW_AWAITING_USER_END: {reason}>>\""
  );
}

module.exports = {
  isWorkflowOff,
  isNextStepPaused,
  nextStepPausedNoticeText,
  readOffClearance,
  evaluateOffClearance,
  isOffClearanceValid,
  isWorktreeOff,
  workflowOffNoticeText,
  worktreeOffNoticeText,
  isIssueCloseVerified,
  issueCloseVerifiedNoticeText,
  isBackgroundWorkInFlight,
  backgroundWorkNoticeText,
  isAwaitingUser,
  consumeAwaitingUser,
  awaitingUserNoticeText,
};
