#!/usr/bin/env node
// Claude Code Stop hook: set ⏳ waiting indicator in VS Code session title.
// Fires at the end of every Claude turn. Skipped for child sessions, completed
// sessions (✓ prefix), and when no title has been set yet.

"use strict";

const fs = require("fs");
const path = require("path");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

try {
  // Hooks are spawned as child processes by Claude Code and may inherit
  // CLAUDE_CODE_CHILD_SESSION=1, which would cause _isChildSession() in
  // session-title.js to suppress all writes. Delete it so this hook — a
  // top-level actor, not a subagent — can write correctly.
  delete process.env.CLAUDE_CODE_CHILD_SESSION;

  let sessionId;
  try {
    const input = JSON.parse(readStdin());
    sessionId = input.session_id;
  } catch (_) {}

  if (sessionId) {
    const { writeWaiting } = require(path.join(__dirname, "lib", "session-title"));
    writeWaiting(sessionId, process.cwd());
  }
} catch (_) {
  // fail-open
}

process.exit(0);
