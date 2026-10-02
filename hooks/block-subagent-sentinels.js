#!/usr/bin/env node
// PreToolUse hook: block workflow-state DOORS issued from a subagent, across all
// three command-executing tools. Both doors are reserved for the orchestrator
// (main conversation): the sentinel echo and the advance-class CLI (#2102).
// Main-conversation calls and non-door commands pass through.
// Unreadable stdin blocks; other error paths approve.

"use strict";

const fs = require("fs");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { isSubagentCall } = require("./lib/subagent-detect");
const { isCommandTool, commandListOf } = require("./lib/tool-command-text");
const { isWorkflowStateDriverCommand } = require("./lib/workflow-driver-commands");
const {
  isStrictSentinel,
  CHAIN_BOUNDARY_SENTINEL_DQ_RE,
  CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
} = require("./lib/sentinel-patterns");

const BLOCK_MESSAGE =
  "subagent cannot emit WORKFLOW sentinels — sentinels are reserved for the orchestrator (main conversation)";

const DRIVER_BLOCK_MESSAGE =
  "subagent cannot drive the workflow state machine — `--advance` is reserved for the orchestrator (main conversation)";

module.exports = { BLOCK_MESSAGE, DRIVER_BLOCK_MESSAGE };

const HOOK_NAME = "block-subagent-sentinels";

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

function isSentinelEmission(command) {
  return (
    isStrictSentinel(command) ||
    CHAIN_BOUNDARY_SENTINEL_DQ_RE.test(command) ||
    CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE.test(command)
  );
}

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
  if (r.kind === "json-invalid") {
    try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
    approve();
  }
  const input = r.input;

  // Step 1: only intercept the three command-executing tools
  if (!isCommandTool(input.tool_name)) approve();

  // Step 2: nothing to adjudicate passes through
  const commands = commandListOf(input.tool_name, input.tool_input);
  if (!commands.length) approve();

  // Step 3: main conversation passes through (agent_id absent)
  if (!isSubagentCall(input)) approve();

  // Step 4: each element on its OWN — sentinel patterns are ^...$ without `m`, so
  // a joined text could never match commands[1], and joining would additionally
  // let two unrelated elements combine into a false driver match.
  for (const raw of commands) {
    const command = String(raw).trim();
    if (!command) continue;
    if (isSentinelEmission(command)) block(BLOCK_MESSAGE);
    if (isWorkflowStateDriverCommand(command)) block(DRIVER_BLOCK_MESSAGE);
  }

  approve();
}
