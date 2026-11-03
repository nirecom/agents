#!/usr/bin/env node
"use strict";
// Fixture hook for tests/hooks/TL3-hook-posttooluse-output-channels.sh (#2824 Step 0).
// probe-hook.js <shape> <nonce>   — answer in one output shape, carrying "PROBE-<nonce>":
//   S1 top-level additionalContext        S2 hookSpecificOutput.additionalContext (PostToolUse)
//   S3 systemMessage                      S4 stderr + exit 2
//   S5 {decision:"block", reason}         S6 Stop systemMessage (silent when stop_hook_active)
//   S7 PreToolUse deny
// probe-hook.js mark <file>       — write <file> when this hook runs (S7: PostToolUse must not run).

const fs = require("node:fs");

const [shape, arg] = process.argv.slice(2);
let input = {};
try { input = JSON.parse(fs.readFileSync(0, "utf8") || "{}"); } catch (_) { input = {}; }
const text = `PROBE-${arg}`;
const out = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

switch (shape) {
  case "S1": out({ additionalContext: text }); break;
  case "S2": out({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text } }); break;
  case "S3": out({ systemMessage: text }); break;
  case "S4": process.stderr.write(text + "\n"); process.exit(2); break;
  case "S5": out({ decision: "block", reason: text }); break;
  case "S6": if (input.stop_hook_active !== true) out({ systemMessage: text }); break;
  case "S7": out({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: text } }); break;
  case "mark": fs.writeFileSync(arg, "ran\n"); break;
  default: process.stderr.write(`probe-hook: unknown shape ${shape}\n`); process.exit(1);
}
process.exit(0);
