#!/usr/bin/env node
"use strict";
// PreToolUse hook: block Read/Edit/Write/Grep/Glob/Bash access to credential files. Absorbs the
// former hooks/block-ssh-private-key.js. WORKFLOW_OFF does NOT bypass this hook.
// Single-member entry; since #2676 settings.json runs it inside hooks/merged-allow-deny.js.
// Dispatch only; the judgment lives in ./block-credentials/judge.js.

const { judgeCredentials } = require("./block-credentials/judge");

module.exports = { judgeCredentials };

if (require.main === module) require("./merged-allow-deny/run").runMembers(["block-credentials"]);
