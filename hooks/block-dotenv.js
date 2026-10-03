#!/usr/bin/env node
// Claude Code PreToolUse hook: block access to .env files and .private-info-allowlist
// Matches: Bash, Read, Grep, Glob, Edit, Write, MultiEdit tools
// Allows: .env.example, .env.sample, .env.template, .env.dist

const fs = require("fs");
const { getBasename } = require("./lib/path-match");
// Detection lives in hooks/lib/dotenv-check.js.
const {
  isDotenvPath,
  checkBashCommand,
  checkAllowDumpCommand,
  isProtectedPath,
  checkGlobPattern,
  checkExploreQuery,
} = require("./lib/dotenv-check");
const { isCommandTool } = require("./lib/tool-command-text");
const { scannableCommandListOf } = require("./lib/scannable-command-list");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-dotenv";

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

const r = readHookInput();
if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
if (r.kind === "json-invalid") {
  try {
    fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n");
  } catch (_) {}
  approve();
}
const input = r.input;

// Session-scoped WORKFLOW override: bypass all .env checks for this session.
const { isWorkflowOff } = require("./lib/session-markers");
if (isWorkflowOff(input.session_id)) approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

if (isCommandTool(toolName)) {
  for (const cmd of scannableCommandListOf(toolName, toolInput)) {
    if (checkBashCommand(cmd)) {
      block("Access to .env files is blocked. Use .env.example for documentation.");
    }
    if (checkAllowDumpCommand(cmd)) {
      block("env-effective-kv --allow-dump is blocked from direct invocation — it can dump every secret in the global .env. Use bin/show-local-env-overrides for key-name-only inspection.");
    }
  }
}

switch (toolName) {
  case "Read":
    if (isDotenvPath(toolInput.file_path)) {
      block("Reading .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "mcp__codegraph__codegraph_explore":
    if (checkExploreQuery(toolInput.query) || isDotenvPath(toolInput.projectPath)) {
      block("Exploring .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Grep":
    if (isDotenvPath(toolInput.path) || checkGlobPattern(toolInput.glob)) {
      block("Searching .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Glob":
    if (checkGlobPattern(toolInput.pattern)) {
      block("Searching for .env files is blocked.");
    }
    break;

  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isDotenvPath(toolInput.file_path)) {
      block("Writing .env files is blocked. Use .env.example for documentation.");
    }
    if (isProtectedPath(toolInput.file_path)) {
      const basename = getBasename(toolInput.file_path);
      if (basename === ".private-info-allowlist") {
        block("Writing .private-info-allowlist is blocked. Edit manually if an exception is genuinely needed.");
      } else {
        block("Writing .offensive-content-blocklist is blocked. Edit manually if a pattern change is genuinely needed.");
      }
    }
    break;

  default:
    break;
}

approve();
