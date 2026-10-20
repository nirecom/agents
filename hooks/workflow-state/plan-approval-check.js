"use strict";
// hooks/workflow-state/plan-approval-check.js — the one approval lookup of the plan-stage gates
// (#2277, #2729), used by next-step --gate, confirm-checkpoint and the Stop hook's presentedStages;
// none reads the CONFIRM_* value or the approval record on its own. The gate classification is
// planGateState's (hooks/lib/confirm-gate/plan-gate.js), the verdict evaluateCompletionApproval's.
// checkPlanApproval(sid, step, opts?) -> { verdict, code, gate, waived }; verdict: approved | unapproved |
// skipped | not-applicable (no state file) | unknown (unreadable state, or the check threw).
// gate: "ON" | "OFF" | "ERROR" (null for a non-gated step); waived: approved by an OFF gate.
// The Skill gate blocks only `unapproved`; side-effect owners stop on anything but `approved`.

const fs = require("fs");

function result(verdict, code, gate, waived) {
  return { verdict, code: code || null, gate: gate || null, waived: waived === true };
}

const GATES = ["ON", "OFF", "ERROR"];

function gateOf(step) {
  try {
    const { rowFor } = require("./plan-stage-table");
    const row = rowFor(step);
    return row ? require("../lib/confirm-gate/plan-gate").planGateState(row.suffix) : null;
  } catch (_) {
    return "ERROR";
  }
}

// opts.gate: the stage's gate the caller already probed (the Stop hook, within its budget).
function checkPlanApproval(sessionId, step, opts) {
  let gate = null;
  try {
    const CA = require("./completion-approval");
    if (!CA.isApprovalGatedStep(step)) return result("unknown", "not-gated-step");
    gate = opts && GATES.includes(opts.gate) ? opts.gate : gateOf(step);
    const { SESSION_ID_VALID_RE, getStatePath, readState } = require("./state-io");
    if (typeof sessionId !== "string" || !SESSION_ID_VALID_RE.test(sessionId)) {
      return result("unknown", "invalid-session", gate);
    }
    if (!fs.existsSync(getStatePath(sessionId))) return result("not-applicable", "no-state-file", gate);
    const state = readState(sessionId);
    if (!state) return result("unknown", "unreadable-state", gate);
    const entry = state.steps && state.steps[step];
    if (entry && entry.status === "skipped") return result("skipped", null, gate);
    const v = CA.evaluateCompletionApproval(sessionId, step, state, { gate });
    const waived = v.approved && v.source === "confirm-flag-off" && gate === "OFF";
    return v.approved ? result("approved", null, gate, waived) : result("unapproved", v.code, gate);
  } catch (_) {
    return result("unknown", "check-threw", gate);
  }
}

module.exports = { checkPlanApproval };
