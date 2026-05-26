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
    "Restore with: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>\""
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

module.exports = {
  isWorkflowOff,
  isWorktreeOff,
  workflowOffNoticeText,
  worktreeOffNoticeText,
};
