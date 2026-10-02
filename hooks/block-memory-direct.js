#!/usr/bin/env node
// PreToolUse hook: block direct Write/Edit/MultiEdit/editFiles and Bash shell
// write-redirects on the memory directory (~/.claude/projects/c--git-agents/memory/).
// See rules/mid-workflow-findings.md.
// Unreadable stdin → block; malformed JSON → fail-open (approve); unresolved session id → block.
// WORKFLOW_OFF is the only bypass.
"use strict";
const fs = require("fs");
const { isWorkflowOff } = require("./lib/session-markers");
const { resolveSessionId } = require("./workflow-state/session-id");
// Detection lives in hooks/lib/memory-path-check.js.
const { hitsMemory, bashHitsMemory } = require("./lib/memory-path-check");
const { isCommandTool } = require("./lib/tool-command-text");
const { scannableCommandListOf } = require("./lib/scannable-command-list");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-memory-direct";

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const BLOCK_MSG =
  "Direct write to ~/.claude/projects/c--git-agents/memory/ is unconditionally blocked; rewording or retrying will not help. " +
  "Agents improvements belong in a public issue — use /issue-create instead. " +
  "See rules/mid-workflow-findings.md.";

const r = readHookInput();
if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
if (r.kind === "json-invalid") {
  try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
  approve();
}
const input = r.input;
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

let memoryHit = false;
if (isCommandTool(toolName)) {
  memoryHit = scannableCommandListOf(toolName, toolInput).some((cmd) => bashHitsMemory(cmd));
}
switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    memoryHit = hitsMemory(toolInput.file_path);
    break;
  default:
    break;
}

if (!memoryHit) approve();

const sid = resolveSessionId({ sessionIdFromInput: input.session_id });
if (sid && isWorkflowOff(sid)) approve();

block(BLOCK_MSG);
