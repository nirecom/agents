#!/usr/bin/env node
// Claude Code PostCompact hook: re-inject session ID into conversation context

const fs = require("fs");
const path = require("path");
const os = require("os");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

let sessionId = null;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id || null;
} catch (e) {}

if (!sessionId) {
  console.log("{}");
  process.exit(0);
}

try {
  const stateDir = process.env.CLAUDE_WORKFLOW_DIR ||
    path.join(os.homedir(), ".claude", "projects", "workflow");
  const lines = [
    `Current workflow session_id: ${sessionId}`,
    `State file: ${path.join(stateDir, sessionId + ".json")}`,
  ];
  console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
} catch (e) {
  console.log("{}");
}
