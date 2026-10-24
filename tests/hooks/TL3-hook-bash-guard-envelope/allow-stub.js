#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-bash-guard-envelope.sh (turn B4).
// Writes hookSpecificOutput.permissionDecision "allow" for every Bash input, the envelope
// #2676 moves the allow-deny hooks to. Never registered in a deployable settings.json.
"use strict";

process.stdin.on("data", () => {});
process.stdin.on("end", () => {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "TL3 allow-stub",
  } }));
  process.exit(0);
});
