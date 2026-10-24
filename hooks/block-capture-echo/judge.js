"use strict";
// hooks/block-capture-echo/judge.js — the block-capture-echo judgment: deny "assign a command
// substitution to a variable, then only display it". No marker (.workflow-off / .worktree-off)
// is honoured: issuance discipline is orthogonal to workflow on/off.

const { isCommandTool, commandListOf } = require("../lib/tool-command-text");
// Imported from the clearance-token scanner because that file is the ONE sanctioned
// site enabling the preserveSubstitutionSpans option (fix-1780-round11 X1/X2).
const { parseWithSubstitutionSpans } = require("../block-clearance-token-write/bash-scan/scan");
const { detectCaptureEcho } = require("./shape");
const { buildRemedy } = require("./remedy");

const NONE = Object.freeze({ decision: "none" });

// PARSE-ONCE contract: the unit is one EXECUTION UNIT (one element of commandListOf), never the
// newline-joined command text, which would fabricate an assignment->echo unit across executions.
/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{decision: "deny"|"none", reason?: string}}
 */
function judgeCaptureEcho(input) {
  if (!input || typeof input !== "object" || !isCommandTool(input.tool_name)) return NONE;
  const units = commandListOf(input.tool_name, input.tool_input);
  if (!Array.isArray(units) || units.length === 0) return NONE;
  for (const unit of units) {
    const hit = detectCaptureEcho(parseWithSubstitutionSpans(unit));
    if (hit) return { decision: "deny", reason: buildRemedy(hit) };
  }
  return NONE;
}

module.exports = { judgeCaptureEcho };
