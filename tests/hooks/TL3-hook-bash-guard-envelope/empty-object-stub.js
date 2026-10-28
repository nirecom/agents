#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-bash-guard-envelope.sh (turn B3).
// Writes an empty JSON object for every Bash input, so the turn measures whether {} counts
// as a decision or as silence. Never registered in a deployable settings.json.
"use strict";

process.stdin.on("data", () => {});
process.stdin.on("end", () => {
  process.stdout.write("{}");
  process.exit(0);
});
