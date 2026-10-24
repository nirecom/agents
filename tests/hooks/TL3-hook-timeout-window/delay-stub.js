#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-timeout-window.sh:
//   node delay-stub.js <ms> <allow|deny|ask> <label>
// Reads the whole input, waits <ms>, then writes that permissionDecision. A wait longer than
// the registration's timeout makes Claude Code cancel the hook before it answers.
// Never registered in a deployable settings.json.
"use strict";

const waitMs = Number(process.argv[2] || 0);
const decision = process.argv[3] || "allow";
const label = process.argv[4] || `${decision}-${waitMs}`;

process.stdin.on("data", () => {});
process.stdin.on("end", () => {
  setTimeout(() => {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: {
      hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: `TL3 delay-stub ${label}`,
    } }));
    process.exit(0);
  }, waitMs);
});
