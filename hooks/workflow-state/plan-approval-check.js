"use strict";
// hooks/workflow-state/plan-approval-check.js — the shared approval lookup of the plan-stage
// gates (#2277). checkPlanApproval(sid, step) -> { verdict, code }, verdict one of:
//   approved        an approval (or an off waiver) is on record and its hash still matches
//   unapproved      the state reads, but no approval is on record or its hash mismatches
//   skipped         the step is skipped
//   not-applicable  this session has no state file (outside the workflow)
//   unknown         the state file exists but does not read, or the check threw
// The Skill gate blocks only `unapproved`; side-effect owners stop on anything but `approved`.

const fs = require("fs");

function result(verdict, code) {
  return { verdict, code: code || null };
}

function checkPlanApproval(sessionId, step) {
  try {
    const CA = require("./completion-approval");
    if (!CA.isApprovalGatedStep(step)) return result("unknown", "not-gated-step");
    const { SESSION_ID_VALID_RE, getStatePath, readState } = require("./state-io");
    if (typeof sessionId !== "string" || !SESSION_ID_VALID_RE.test(sessionId)) {
      return result("unknown", "invalid-session");
    }
    if (!fs.existsSync(getStatePath(sessionId))) return result("not-applicable", "no-state-file");
    const state = readState(sessionId);
    if (!state) return result("unknown", "unreadable-state");
    const entry = state.steps && state.steps[step];
    if (entry && entry.status === "skipped") return result("skipped");
    const v = CA.evaluateCompletionApproval(sessionId, step, state);
    return v.approved ? result("approved") : result("unapproved", v.code);
  } catch (_) {
    return result("unknown", "check-threw");
  }
}

module.exports = { checkPlanApproval };
