#!/usr/bin/env node
"use strict";
// PreToolUse hook: auto-approves low-risk tool calls — background Monitor polling, EnterWorktree
// moves inside WORKTREE_BASE_DIR, and `bash <this session's scratchpad>.sh`. It only ever ADDS an
// allow; any missing input or config falls through to "{}", leaving the confirm flow in control.
// Since #2676 settings.json runs it inside hooks/merged-allow-deny.js.
// Dispatch + re-export only; the judgment lives in ./preuse-auto-approve/judge.js.

const { normalizeForCompare, isInsideBase } = require("./preuse-auto-approve/path-compare");
const { judgeAutoApprove } = require("./preuse-auto-approve/judge");

module.exports = { normalizeForCompare, isInsideBase, judgeAutoApprove };

if (require.main === module) require("./merged-allow-deny/run").runMembers(["preuse-auto-approve"]);
