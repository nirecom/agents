#!/usr/bin/env node
// PreToolUse hook (matcher Skill): refuses to start the skill that follows a gated plan stage
// (make-outline-plan / make-detail-plan / write-tests) while that stage's approval is not on
// record (#2277). A deterrent only: it denies on `unapproved` and stays silent otherwise —
// stopping a skill on unreadable state would also cut off the way back. Never emits allow.
"use strict";

const fs = require("fs");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

function deny(reason) {
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  }) + "\n");
}

function denyReason(step, row) {
  return "[plan-approval] The " + row.suffix + " stage (" + step + ") has no approval on record, so " +
    row.nextSkill + " cannot start. End the final body text of a presentation turn with the plan-link line " +
    "and close the turn; after the user replies, emit " + row.sentinel + " (the CONFIRM_" +
    row.suffix.toUpperCase() + " echo) on its own. (Hook: gate-plan-skill-advance.js)";
}

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic("gate-plan-skill-advance", r, "gate skipped") + "\n"); } catch (_) {}
    return;
  }
  const input = r.input;
  if (!input || typeof input !== "object" || input.tool_name !== "Skill") return;
  const skill = input.tool_input && typeof input.tool_input === "object" ? input.tool_input.skill : null;
  const { priorStepForSkill, rowFor } = require("./workflow-state/plan-stage-table");
  const step = priorStepForSkill(skill);
  if (!step || typeof input.session_id !== "string" || !input.session_id) return;
  const { checkPlanApproval } = require("./workflow-state/plan-approval-check");
  if (checkPlanApproval(input.session_id, step).verdict === "unapproved") deny(denyReason(step, rowFor(step)));
}

if (require.main === module) {
  try { main(); } catch (_) { /* fail-open: a deterrent never breaks the tool call */ }
  process.exit(0);
}

module.exports = { main };
