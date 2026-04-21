#!/usr/bin/env node
// Temporary landing-gate stub: dumps PreToolUse stdin to stderr for empirical verification.
// Remove this file and its settings.json entry after recording agent_id behavior.

const fs = require("fs");

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

const raw = readStdin();
let input = {};
try { input = JSON.parse(raw); } catch (e) {}

const record = {
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
