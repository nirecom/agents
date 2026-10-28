#!/usr/bin/env node
"use strict";
// Claude Code PreToolUse hook: block access to .env files and .private-info-allowlist.
// Single-member entry; since #2676 settings.json runs it inside hooks/merged-allow-deny.js.
// Dispatch only; the judgment lives in ./block-dotenv/judge.js.

const { judgeDotenv } = require("./block-dotenv/judge");

module.exports = { judgeDotenv };

if (require.main === module) require("./merged-allow-deny/run").runMembers(["block-dotenv"]);
