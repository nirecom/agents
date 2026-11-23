"use strict";
// hooks/preuse-auto-approve/judge.js — the preuse-auto-approve judgment: allow low-risk calls
// (background Monitor polling, `bash <this session's scratchpad>.sh`). It only ever ADDS an allow:
// every other path is "none", never a deny. EnterWorktree gets no decision (#1610): the default
// in-repo base needs no dialog, and an explicit base outside the repo keeps the upstream one.
// The caller loads the default .env first (AUTO_APPROVE_TOOLS).

const { isCommandTool, commandListOf } = require("../lib/tool-command-text");
const { isAllowedScratchpadInvocation } = require("./scratchpad-script");

const NONE = Object.freeze({ decision: "none" });
const allow = (reason) => ({ decision: "allow", reason });

function judgeCommand(tool, input) {
  let units = null;
  try {
    units = commandListOf(tool, input.tool_input);
  } catch (_e) {
    return NONE;
  }
  // One execution unit only: a list is several independent commands, and this
  // allow covers exactly one `bash <scratchpad script>` invocation.
  if (Array.isArray(units) && units.length === 1 && isAllowedScratchpadInvocation(units[0])) {
    return allow("Scratchpad script auto-approved: bash invocation of a .sh file inside this session's scratchpad");
  }
  return NONE;
}

/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{decision: "allow"|"none", reason?: string}}
 */
function judgeAutoApprove(input) {
  if (!input || typeof input !== "object") return NONE;
  const autoApprove = process.env.AUTO_APPROVE_TOOLS;
  if (typeof autoApprove === "string" && autoApprove.trim().toLowerCase() === "off") return NONE;
  const tool = input.tool_name;
  if (tool === "Monitor") return allow("Monitor auto-approved: low-risk background monitoring");
  if (isCommandTool(tool)) return judgeCommand(tool, input);
  return NONE;
}

module.exports = { judgeAutoApprove };
