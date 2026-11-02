"use strict";
// The exits both lanes of stop-final-report-guard honour (#1192), decided once per Stop and named
// in every block reason through EXIT_HATCH_TEXT, so lanes A and B never drift apart.

const fs = require("fs");

const EXIT_HATCH_TEXT =
  "Exits that end this block: turn workflow enforcement off for this session " +
  "(the workflow-off marker), or let /session-close yield to the supervisor " +
  "(session-close gate `yield`).";

function readGateAction(sid) {
  const controlDir = require("../workflow-state/state-io/control-dir");
  try {
    const gate = JSON.parse(fs.readFileSync(controlDir.controlPath(sid, "session-close-gate.json"), "utf8"));
    return gate && typeof gate === "object" ? gate.gate_action : null;
  } catch (e) {
    try { controlDir.diagnoseControlMigration(e, "stop-final-report-guard"); } catch (_) { /* fail-open */ }
    return null;
  }
}

// { exit, reason }: the workflow-off marker first, then the yield gate. An error reading the
// marker exits too, matching the guard's fail-open contract.
function shouldYieldOrBypass(sid) {
  try {
    if (require("../lib/session-markers").isWorkflowOff(sid)) return { exit: true, reason: "workflow-off" };
  } catch (_) {
    return { exit: true, reason: "workflow-off-unreadable" };
  }
  if (readGateAction(sid) === "yield") return { exit: true, reason: "session-close-yield" };
  return { exit: false, reason: null };
}

module.exports = { EXIT_HATCH_TEXT, shouldYieldOrBypass };
