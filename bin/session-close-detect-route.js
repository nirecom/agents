#!/usr/bin/env node
// Print the /session-close route for a session (#2527; absorbs the former
// session-close-detect-wf-meta.js).
//
// Usage: node session-close-detect-route.js --session <sid>
// Outputs: "ROUTE=wf-meta|pull_request|direct" to stdout. wf-meta wins; otherwise the
// recorded delivery_path, else the live provisional value (resolveSessionProfile).
// Exit 0 always once <sid> is given (a missing state reads as nothing recorded).
// Exit 1 when --session <sid> is missing (usage error).

"use strict";
const path = require("path");

const USAGE = "Usage: session-close-detect-route.js --session <sid>\n";

function parseSid(argv) {
  if (argv.length === 2 && argv[0] === "--session" && argv[1]) return argv[1];
  process.stderr.write(USAGE);
  process.exit(1);
}

const sessionId = parseSid(process.argv.slice(2));

let route = "pull_request";
try {
  const { readState } = require(path.resolve(__dirname, "../hooks/workflow-state"));
  const { resolveSessionProfile } = require(path.resolve(__dirname, "../hooks/workflow-state/session-profile"));
  let state = null;
  try { state = readState(sessionId); } catch (_) { state = null; }
  const profile = resolveSessionProfile(state, sessionId);
  route = profile.deliverableType === "wf-meta" ? "wf-meta" : profile.deliveryPath;
} catch (e) {
  process.stderr.write("session-close-detect-route: " + (e && e.message ? e.message : "resolve failed") + "\n");
}
process.stdout.write("ROUTE=" + route + "\n");
process.exit(0);
