#!/usr/bin/env node
// Claude Code PreToolUse hook: block access to .env files and .private-info-allowlist
// Matches: Bash, Read, Grep, Glob, Edit, Write, MultiEdit tools
// Allows: .env.example, .env.sample, .env.template, .env.dist

const fs = require("fs");
const { getBasename } = require("./lib/path-match");
// Detection lives in hooks/lib/dotenv-check.js (shared with the
// scratchpad-script auto-approve body scan).
const {
  isDotenvPath,
  checkBashCommand,
  isProtectedPath,
  checkGlobPattern,
} = require("./lib/dotenv-check");

// Read stdin (cross-platform: fs.readSync for Windows compatibility)
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {
    // EOF or error
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Parse stdin
let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  // Invalid JSON — approve (fail-open for non-matching input)
  approve();
}

// Session-scoped WORKFLOW override: bypass all .env checks for this session.
const { isWorkflowOff } = require("./lib/session-markers");
if (isWorkflowOff(input.session_id)) approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (checkBashCommand(toolInput.command)) {
      block("Access to .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Read":
    if (isDotenvPath(toolInput.file_path)) {
      block("Reading .env files is blocked. Use .env.example for documentation.");
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
