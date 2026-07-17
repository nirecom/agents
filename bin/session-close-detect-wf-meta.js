#!/usr/bin/env node
// Detect whether a session is a WF-META session.
//
// Usage: node session-close-detect-wf-meta.js <session-id>
// Outputs: "yes" or "no" (no newline) to stdout.
// Exit 0 always (graceful fallback on any error).
// Exit 1 when <session-id> is missing (usage error).

"use strict";
const path = require("path");

const sessionId = process.argv[2];
if (!sessionId) {
  process.stderr.write("Usage: session-close-detect-wf-meta.js <session-id>\n");
  process.exit(1);
}

let answer = "no";
try {
  const { readState } = require(path.resolve(__dirname, "../hooks/lib/workflow-state"));
  const state = readState(sessionId);
  if (state && state.workflow_type === "wf-meta") answer = "yes";
} catch (_) {
  answer = "no";
}
process.stdout.write(answer);
process.exit(0);
