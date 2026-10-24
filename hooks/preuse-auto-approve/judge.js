"use strict";
// hooks/preuse-auto-approve/judge.js — the preuse-auto-approve judgment: allow low-risk calls
// (background Monitor polling, EnterWorktree inside WORKTREE_BASE_DIR, `bash <this session's
// scratchpad>.sh`). It only ever ADDS an allow: every other path is "none", never a deny.
// The caller loads the default .env first (WORKTREE_BASE_DIR, AUTO_APPROVE_TOOLS).

const fs = require("fs");
const { isCommandTool, commandListOf } = require("../lib/tool-command-text");
const { isAllowedScratchpadInvocation } = require("./scratchpad-script");
const { isInsideBase } = require("./path-compare");

const NONE = Object.freeze({ decision: "none" });
const allow = (reason) => ({ decision: "allow", reason });

const isBlank = (value) => typeof value !== "string" || value.trim().length === 0;

function judgeEnterWorktree(input) {
  const base = process.env.WORKTREE_BASE_DIR;
  if (isBlank(base)) return NONE;
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const targetPath = toolInput.path;
  if (isBlank(targetPath)) return NONE;
  // Resolve symlinks so a symlink inside WORKTREE_BASE_DIR that points outside cannot bypass
  // the boundary check; an unresolvable path is compared as given.
  let resolvedPath = targetPath;
  try {
    resolvedPath = fs.realpathSync(targetPath);
  } catch (_e) {
    resolvedPath = targetPath;
  }
  return isInsideBase(resolvedPath, base) ? allow("EnterWorktree auto-approved: path is within WORKTREE_BASE_DIR") : NONE;
}

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
  if (tool === "EnterWorktree") return judgeEnterWorktree(input);
  if (isCommandTool(tool)) return judgeCommand(tool, input);
  return NONE;
}

module.exports = { judgeAutoApprove };
