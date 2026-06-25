#!/usr/bin/env node
// Claude Code Stop hook: clear ⏳ indicator when Claude finishes responding.
// Fires at the end of every Claude turn. Skipped when no ⏳ is present.

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
    // transcript_path is the actual JSONL file; use it directly so worktree
    // sessions (where CLAUDE_PROJECT_DIR is the worktree path, not main repo)
    // resolve to the correct file instead of a phantom encoded path.
    if (input.transcript_path) process.env.CLAUDE_SESSION_JSONL_PATH = input.transcript_path;
  } catch (_) {}

  if (sessionId) {
    const { writeClearWaiting } = require(path.join(__dirname, "lib", "session-title"));
    writeClearWaiting(sessionId, process.cwd());
  }
} catch (_) {
  // fail-open
}

process.exit(0);
