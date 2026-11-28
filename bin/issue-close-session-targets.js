#!/usr/bin/env node
// Usage: node issue-close-session-targets.js --session <sid> [--owner-repo <owner/repo>]
// Prints {"closed":[label],"open":[label],"unknown":[label]} for the session's closes_issues (#3043).
// Exit 0 on success; 1 on a usage error or an invalid session id.
"use strict";
process.exitCode = require("./issue-close-session-targets/run").main(process.argv.slice(2));
