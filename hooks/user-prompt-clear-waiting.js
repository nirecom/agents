#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: set ⏳ indicator when the user submits
// a message — signals that the user is now waiting for Claude to respond.

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
  } catch (_) {}

  if (sessionId) {
    const { writeWaiting } = require(path.join(__dirname, "lib", "session-title"));
    writeWaiting(sessionId, process.cwd());
  }
} catch (_) {
  // fail-open
}

process.exit(0);
