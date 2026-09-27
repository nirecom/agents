#!/usr/bin/env node
// Test-only PreToolUse stub for tests/hooks/TL3-hook-bash-guard-envelope.sh (turn B2).
// Prints nothing and exits 0 -- the #2264 passThrough envelope -- so the turn measures
// the normal permission flow a silent hook leaves in place. Never registered in a
// deployable settings.json.
"use strict";

process.stdin.on("data", () => {});
process.stdin.on("end", () => { process.exit(0); });
