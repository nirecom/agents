#!/usr/bin/env node
// Claude Code PreToolUse hook (AskUserQuestion): clear ⏳ when Claude shows
// a dialog — at that point Claude is waiting for user input, not processing.

"use strict";

const fs = require("fs");
const path = require("path");

// Remove CLAUDE_CODE_CHILD_SESSION so session-title.js write functions are
// not silently suppressed (hooks may inherit this env var from Claude Code).
delete process.env.CLAUDE_CODE_CHILD_SESSION;

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
  let sessionId;
  try {
    const input = JSON.parse(readStdin());
    sessionId = input.session_id;
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
