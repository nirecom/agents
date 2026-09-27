#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-bash-guard-envelope.sh (turn B1).
// Replays the pre-#2264 bash-guard NO_HIT output, {decision:"approve"}, for every Bash
// input, so the turn measures what that legacy envelope does to the permission prompt.
// Never registered in a deployable settings.json.
"use strict";

let buf = "";
process.stdin.on("data", (c) => { buf += c; });
process.stdin.on("end", () => {
  process.stdout.write(JSON.stringify({ decision: "approve" }));
  process.exit(0);
});
