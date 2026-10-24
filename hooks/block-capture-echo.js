#!/usr/bin/env node
"use strict";
// PreToolUse hook: refuses "assign a command substitution to a variable, then do nothing but
// display it" — the model should reissue the inner command bare and read its stdout instead
// (rules/shell-commands.md, Command-Line Issuance Discipline). Unconditional deny: no marker is
// honoured. Since #2676 settings.json runs it inside hooks/merged-allow-deny.js.
// Dispatch only; the judgment lives in ./block-capture-echo/judge.js.

const { judgeCaptureEcho } = require("./block-capture-echo/judge");

function main() {
  require("./merged-allow-deny/run").runMembers(["block-capture-echo"]);
}

module.exports = { main, judgeCaptureEcho };

if (require.main === module) main();
