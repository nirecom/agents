#!/usr/bin/env node
// PreToolUse hook: block direct Write/Edit/MultiEdit/editFiles and Bash shell
// write-redirects on the memory directory (~/.claude/projects/c--git-agents/memory/).
// See rules/mid-workflow-findings.md.
// Unparseable input → fail-open (approve); unresolved session id → fail-closed (block).
// WORKFLOW_OFF is the only bypass.
"use strict";
const fs = require("fs");
const { isWorkflowOff } = require("./lib/session-markers");
const { resolveSessionId } = require("./workflow-state/session-id");
// Detection lives in hooks/lib/memory-path-check.js.
const { hitsMemory, bashHitsMemory } = require("./lib/memory-path-check");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const BLOCK_MSG =
  "Direct write to ~/.claude/projects/c--git-agents/memory/ is unconditionally blocked; rewording or retrying will not help. " +
  "Agents improvements belong in a public issue — use /issue-create instead. " +
  "See rules/mid-workflow-findings.md.";

let input;
try {
  input = JSON.parse(readStdin());
} catch (_e) {
  approve();
}
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

let memoryHit = false;
switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    memoryHit = hitsMemory(toolInput.file_path);
    break;
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    memoryHit = bashHitsMemory(toolInput.command);
    break;
  default:
    break;
}

if (!memoryHit) approve();

const sid = resolveSessionId({ sessionIdFromInput: input.session_id });
if (sid && isWorkflowOff(sid)) approve();

block(BLOCK_MSG);
