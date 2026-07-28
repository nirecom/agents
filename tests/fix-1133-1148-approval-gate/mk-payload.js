#!/usr/bin/env node
"use strict";
// PostToolUse-payload builder for workflow-mark.js stdin (NOT a test itself).
// Usage: node mk-payload.js '<command>' '<session_id>'
// Emits the JSON envelope workflow-mark.js expects (Bash tool, exit_code 0).

const command = process.argv[2] || "";
const sessionId = process.argv[3] || "";

process.stdout.write(JSON.stringify({
  tool_name: "Bash",
  tool_input: { command },
  tool_response: { output: command, exit_code: 0 },
  session_id: sessionId,
}));
