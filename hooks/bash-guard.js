#!/usr/bin/env node
"use strict";
// hooks/bash-guard.js — PreToolUse entrypoint for the command-line issuance guard (#2134).
// Dispatch + re-export only; the verdict lives in ./bash-guard/judge.js and the forbidden set in
// ./bash-guard/forbidden-literals.js. Since #2676 settings.json runs it inside
// hooks/merged-allow-deny.js, which routes only "Bash" to it: runInTerminal / runCommands can
// drive pwsh, where a backtick is a line continuation. Unreadable stdin denies (fail-close);
// malformed JSON prints nothing (one stderr diagnostic) rather than a verdict invented from nothing.

const { judgeBashCommand } = require("./bash-guard/judge");

module.exports = { judgeBashCommand };

if (require.main === module) require("./merged-allow-deny/run").runMembers(["bash-guard"]);
