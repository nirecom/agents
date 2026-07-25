// hooks/lib/session-markers.js — session-marker readers (SSOT for workflow-off and worktree-off)
"use strict";

const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("./workflow-state");

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
};
