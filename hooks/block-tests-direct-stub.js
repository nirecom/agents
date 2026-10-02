#!/usr/bin/env node
// Temporary landing-gate stub: dumps PreToolUse stdin to stderr for empirical verification.
// Remove this file and its settings.json entry after recording agent_id behavior.

const { readHookInput } = require("./lib/read-stdin");

const r = readHookInput();
const input = (r.kind === "ok" && r.input) || {};

const record = {
  stdin: r.kind,
  tool_name: input.tool_name,
  session_id: input.session_id,
  agent_id: input.agent_id ?? "(not present)",
  agent_type: input.agent_type ?? "(not present)",
  file_path: (input.tool_input || {}).file_path ?? "(none)",
  hook_event_name: input.hook_event_name,
};

const logPath = require("path").join(require("os").homedir(), ".claude", "block-tests-direct-stub.log");
require("fs").appendFileSync(logPath, new Date().toISOString() + " " + JSON.stringify(record) + "\n", "utf8");

// Observation complete — always approve.
console.log(JSON.stringify({ decision: "approve" }));
