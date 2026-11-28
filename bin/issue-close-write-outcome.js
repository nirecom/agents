#!/usr/bin/env node
// Write or update a per-issue entry in <CONTROL_DIR>/issue-close-outcome.json.
// Usage:
//   node issue-close-write-outcome.js <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>
//   node issue-close-write-outcome.js --session <sid> --empty
//   node issue-close-write-outcome.js --session-id <sid> --out-file <path> [--issue-repo <r>] [--owner-repo <r>] <N> <state> ...
//   node issue-close-write-outcome.js --non-github|--wf-meta <issues-json-array> <outcome-file>
//   node issue-close-write-outcome.js --fallback <intent-md> <outcome-file>
// Entries match by (repo normalized by the bag's homeRepo, N); see hooks/lib/issue-identity.js.
// Normal mode and --empty resolve the outcome file through the control-dir resolver.
// Exit 0 on success or skip (session-id unresolvable); 1 on error (stderr).

"use strict";
const fixed = require("./issue-close-write-outcome/fixed-modes");
const session = require("./issue-close-write-outcome/session-mode");

function main(args) {
  if (args[0] === "--session" && args[2] === "--empty") return fixed.runEmpty(args[1]);
  if (fixed.LIST_STATES[args[0]]) return fixed.runList(args[0], args[1], args[2]);
  if (args[0] === "--fallback") return fixed.runFallback(args[1], args[2]);
  if (args[0] === "--session-id") return session.runSessionId(args);
  return session.runNormal(args);
}

process.exitCode = main(process.argv.slice(2));
