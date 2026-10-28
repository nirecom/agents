#!/usr/bin/env node
"use strict";
// hooks/merged-allow-deny.js — PreToolUse entry of the merged allow-deny hook (#2676): block-dotenv,
// block-credentials, bash-guard, block-capture-echo and preuse-auto-approve judged in one process.
// settings.json registers it once per matcher group: `--matcher-group primary|monitor-worktree`.
// Dispatch only; the members live in ./merged-allow-deny/members.js.

const { runMembers } = require("./merged-allow-deny/run");
const { MEMBERS } = require("./merged-allow-deny/members");

function matcherGroupOf(argv) {
  const at = argv.indexOf("--matcher-group");
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : undefined;
}

if (require.main === module) {
  runMembers(MEMBERS.map((member) => member.name), {
    entryName: "merged-allow-deny",
    matcherGroup: matcherGroupOf(process.argv.slice(2)),
    routeByTool: true,
  });
}

module.exports = { matcherGroupOf };
