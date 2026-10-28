"use strict";
// hooks/block-dotenv/judge.js — the block-dotenv judgment: deny access to .env files and to
// .private-info-allowlist / .offensive-content-blocklist writes; approve everything else.
// Allowed: .env.example, .env.sample, .env.template, .env.dist. A WORKFLOW_OFF session approves.

const { getBasename } = require("../lib/path-match");
const {
  isDotenvPath,
  checkBashCommand,
  checkAllowDumpCommand,
  isProtectedPath,
  checkGlobPattern,
  checkExploreQuery,
} = require("../lib/dotenv-check");
const { isCommandTool } = require("../lib/tool-command-text");
const { scannableCommandListOf } = require("../lib/scannable-command-list");
const { isWorkflowOff } = require("../lib/session-markers");

const APPROVE = Object.freeze({ decision: "approve" });
const deny = (reason) => ({ decision: "deny", reason });

const MSG = Object.freeze({
  command: "Access to .env files is blocked. Use .env.example for documentation.",
  allowDump: "env-effective-kv --allow-dump is blocked from direct invocation — it can dump every secret in the global .env. Use bin/show-local-env-overrides for key-name-only inspection.",
  read: "Reading .env files is blocked. Use .env.example for documentation.",
  explore: "Exploring .env files is blocked. Use .env.example for documentation.",
  grep: "Searching .env files is blocked. Use .env.example for documentation.",
  glob: "Searching for .env files is blocked.",
  write: "Writing .env files is blocked. Use .env.example for documentation.",
  allowlist: "Writing .private-info-allowlist is blocked. Edit manually if an exception is genuinely needed.",
  blocklist: "Writing .offensive-content-blocklist is blocked. Edit manually if a pattern change is genuinely needed.",
});

function judgeCommand(toolName, toolInput) {
  for (const cmd of scannableCommandListOf(toolName, toolInput)) {
    if (checkBashCommand(cmd)) return deny(MSG.command);
    if (checkAllowDumpCommand(cmd)) return deny(MSG.allowDump);
  }
  return null;
}

function judgeWrite(filePath) {
  if (isDotenvPath(filePath)) return deny(MSG.write);
  if (!isProtectedPath(filePath)) return APPROVE;
  return deny(getBasename(filePath) === ".private-info-allowlist" ? MSG.allowlist : MSG.blocklist);
}

function judgeByTool(toolName, toolInput) {
  switch (toolName) {
    case "Read":
      return isDotenvPath(toolInput.file_path) ? deny(MSG.read) : APPROVE;
    case "mcp__codegraph__codegraph_explore":
      return checkExploreQuery(toolInput.query) || isDotenvPath(toolInput.projectPath) ? deny(MSG.explore) : APPROVE;
    case "Grep":
      return isDotenvPath(toolInput.path) || checkGlobPattern(toolInput.glob) ? deny(MSG.grep) : APPROVE;
    case "Glob":
      return checkGlobPattern(toolInput.pattern) ? deny(MSG.glob) : APPROVE;
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "editFiles":
      return judgeWrite(toolInput.file_path);
    default:
      return APPROVE;
  }
}

/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{decision: "deny"|"approve", reason?: string}}
 */
function judgeDotenv(input) {
  const payload = input || {};
  if (isWorkflowOff(payload.session_id)) return APPROVE;
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};
  if (isCommandTool(toolName)) {
    const commandResult = judgeCommand(toolName, toolInput);
    if (commandResult) return commandResult;
  }
  return judgeByTool(toolName, toolInput);
}

module.exports = { judgeDotenv };
