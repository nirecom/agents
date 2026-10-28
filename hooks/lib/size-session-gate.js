"use strict";
// hooks/lib/size-session-gate.js — does this session get the size check? (#2631)
// sizeCheckState: "exempt" (no sid, WORKFLOW_OFF, no state file), "active" (a readable state, settled
// step or not) or "unknown" (unreadable state, a throw). CONFIRM checks every non-exempt state (fail-closed);
// edit time checks only "active" (sizeCheckActive, fail-open).
// Commit time: an unresolved sid is still checked, a known sid without state is not.
// The only exemptions are WORKFLOW_OFF and never-started sessions; WORKTREE_OFF exempts nothing.

const fs = require("fs");

function sizeCheckState(sid) {
  if (typeof sid !== "string" || sid.length === 0) return "exempt";
  try {
    const { isWorkflowOff } = require("./session-markers");
    if (isWorkflowOff(sid)) return "exempt";
    const { getStatePath, readState } = require("../workflow-state/state-io/core");
    if (!fs.existsSync(getStatePath(sid))) return "exempt";
    return readState(sid) === null ? "unknown" : "active";
  } catch (_e) {
    return "unknown";
  }
}

function sizeCheckActive(sid) {
  return sizeCheckState(sid) === "active";
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

module.exports = { sizeCheckState, sizeCheckActive, commitSizeCheckActive };
