"use strict";
// hooks/lib/size-session-gate.js — does this session get the size check? (#2631)
// Edit time and CONFIRM: only a started, non-WORKFLOW_OFF session (sizeCheckActive).
// Commit time: an unresolved sid is still checked, a known sid without state is not.
// The only exemptions are WORKFLOW_OFF and never-started sessions; WORKTREE_OFF exempts nothing.

const fs = require("fs");

function sizeCheckActive(sid) {
  try {
    if (typeof sid !== "string" || sid.length === 0) return false;
    const { isWorkflowOff } = require("./session-markers");
    if (isWorkflowOff(sid)) return false;
    const { isWorkflowStarted } = require("../workflow-state/lifecycle");
    return isWorkflowStarted(sid) === true;
  } catch (_e) {
    return false;
  }
}

function commitSizeCheckActive(sid) {
  if (typeof sid !== "string" || sid.length === 0) return true;
  try {
    const { isWorkflowOff } = require("./session-markers");
    if (isWorkflowOff(sid)) return false;
    const { getStatePath } = require("../workflow-state/state-io/core");
    return fs.existsSync(getStatePath(sid));
  } catch (_e) {
    return true;
  }
}

module.exports = { sizeCheckActive, commitSizeCheckActive };
