#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-bash-guard-envelope.sh (turns C2/C3).
// Stands in for a sibling guard (workflow-gate, enforce-worktree): it returns the same
// {decision:"block"} shape those hooks emit, but ONLY for a command carrying the fixed
// marker, and prints nothing otherwise. Never registered in a deployable settings.json.
"use strict";

const MARKER = "BG_PROBE_BLOCK_MARKER";
// The reason carries its own token so a refusal can be attributed to THIS stub.
const REASON = "probe: BG_PROBE_COMPANION_BLOCKED";

let buf = "";
process.stdin.on("data", (c) => { buf += c; });
process.stdin.on("end", () => {
  let cmd = "";
  try {
    const input = JSON.parse(buf);
    cmd = String(((input || {}).tool_input || {}).command || "");
  } catch (e) {
    cmd = "";
  }
  if (cmd.indexOf(MARKER) !== -1) {
    process.stdout.write(JSON.stringify({ decision: "block", reason: REASON }));
  }
  process.exit(0);
});
