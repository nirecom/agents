#!/usr/bin/env node
// Render SC-7 supervisor alert findings (post-Final-Report surfacing).
//
// Usage: node session-close-render-sc7.js <supervisor-state-json-path> <session-id>
// Outputs: rendered findings text (trailing newline) to stdout, or empty if none.
// Exit 0 on success or absent state file; exit 1 on usage error or malformed JSON.

"use strict";
const fs = require("fs");
const path = require("path");

const statePath = process.argv[2];
const sessionId = process.argv[3];
if (!statePath) {
  process.stderr.write("Usage: session-close-render-sc7.js <supervisor-state-json-path> <session-id>\n");
  process.exit(1);
}

let raw;
try {
  raw = fs.readFileSync(statePath, "utf8");
} catch (err) {
  if (err && err.code === "ENOENT") process.exit(0);
  process.stderr.write(`session-close-render-sc7: cannot read ${statePath}: ${err.message}\n`);
  process.exit(1);
}

let st;
try {
  st = JSON.parse(raw);
} catch (err) {
  process.stderr.write(`session-close-render-sc7: invalid JSON in ${statePath}: ${err.message}\n`);
  process.exit(1);
}

if (st.alert && st.alert.findings_surfaced_at !== null && st.alert.findings_surfaced_at !== undefined) {
  process.exit(0);
}

const { formatLayer2Findings } = require(path.resolve(__dirname, "../hooks/lib/supervisor-findings-render"));
const result = formatLayer2Findings(st.alert ? (st.alert.findings || []) : [], {
  sessionId,
  workflowSessionId: process.env.CLAUDE_SESSION_ID || null,
  supervisorPath: process.env.AGENTS_CONFIG_DIR ? process.env.AGENTS_CONFIG_DIR + "/agents/supervisor.md" : null,
  stateFilePath: statePath,
  summaryOnly: true,
});
if (result) process.stdout.write(result + "\n");
process.exit(0);
