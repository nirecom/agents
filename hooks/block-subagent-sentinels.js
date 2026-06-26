#!/usr/bin/env node
// PreToolUse hook: block WORKFLOW sentinel echos issued from a subagent.
// Sentinels are reserved for the orchestrator (main conversation); a subagent
// must never drive the workflow state machine. Main-conversation calls and
// non-sentinel commands pass through. Fail-open: any error path approves.

"use strict";

const fs = require("fs");
const { isSubagentCall } = require("./lib/subagent-detect");
const {
  isStrictSentinel,
  CHAIN_BOUNDARY_SENTINEL_DQ_RE,
  CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
} = require("./lib/sentinel-patterns");

const BLOCK_MESSAGE =
  "subagent cannot emit WORKFLOW sentinels — sentinels are reserved for the orchestrator (main conversation)";

module.exports = { BLOCK_MESSAGE };

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block() {
  console.log(JSON.stringify({ decision: "block", reason: BLOCK_MESSAGE }));
  process.exit(0);
}

if (require.main === module) {
  let input = {};
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    approve(); // fail-open on malformed stdin
  }

  // Step 1: only intercept Bash
  if (input.tool_name !== "Bash") approve();

  // Step 2: empty command passes through
  const command = ((input.tool_input || {}).command || "").trim();
  if (!command) approve();

  // Step 3: main conversation passes through (agent_id absent)
  if (!isSubagentCall(input)) approve();

  // Step 4: block sentinel echos using SSOT detectors (no naive `&&` split)
  if (
    isStrictSentinel(command) ||
    CHAIN_BOUNDARY_SENTINEL_DQ_RE.test(command) ||
    CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE.test(command)
  ) {
    block();
  }

  approve();
}
