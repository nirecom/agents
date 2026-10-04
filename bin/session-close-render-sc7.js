#!/usr/bin/env node
// Render SC-7 supervisor alert findings (post-Final-Report surfacing).
//
// Usage: node session-close-render-sc7.js --session <session-id>
//   reads <CLAUDE_WORKFLOW_DIR>/<sid>.control/supervisor-state.json.
// Legacy: <supervisor-state-json-path> <session-id> — accepted only as the derived path or its
//   <sid>-supervisor-state.json basename.
// Outputs: rendered findings text (trailing newline) to stdout, or empty if none.
// Exit 0 on success or absent state file; exit 1 on usage error, rejected path or malformed JSON.

"use strict";
const fs = require("fs");
const path = require("path");

const { resolveControlFile } = require(path.join(__dirname, "lib", "session-control-file"));

const USAGE = "Usage: session-close-render-sc7.js --session <session-id>\n";

function fail(msg) {
  process.stderr.write(msg);
  process.exit(1);
}

const argv = process.argv.slice(2);
let sessionId;
let legacy;
if (argv[0] === "--session") {
  if (argv.length !== 2) fail(USAGE);
  sessionId = argv[1];
} else {
  [legacy, sessionId] = argv;
  if (!legacy) fail(USAGE);
}

let statePath;
try {
  statePath = resolveControlFile({ sid: sessionId, legacy, name: "supervisor-state.json", forWrite: false });
} catch (err) {
  fail(`session-close-render-sc7: ${err.message}\n`);
}

let raw;
try {
  raw = fs.readFileSync(statePath, "utf8");
} catch (err) {
  if (err && err.code === "ENOENT") process.exit(0);
  fail(`session-close-render-sc7: cannot read ${statePath}: ${err.message}\n`);
}

let st;
try {
  st = JSON.parse(raw);
} catch (err) {
  fail(`session-close-render-sc7: invalid JSON in ${statePath}: ${err.message}\n`);
}

if (st.alert && st.alert.findings_surfaced_at !== null && st.alert.findings_surfaced_at !== undefined) {
  process.exit(0);
}

const { formatLayer2Findings } = require(path.resolve(__dirname, "../hooks/lib/supervisor-findings-render"));
const result = formatLayer2Findings(st.alert ? (st.alert.findings || []) : [], {
  sessionId,
  workflowSessionId: null,
  supervisorPath: process.env.AGENTS_CONFIG_DIR ? process.env.AGENTS_CONFIG_DIR + "/agents/supervisor.md" : null,
  stateFilePath: statePath,
  summaryOnly: true,
});
if (result) process.stdout.write(result + "\n");
process.exit(0);
