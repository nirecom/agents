#!/usr/bin/env node
// Claude Code SessionStart hook: set CLAUDE_SESSION_ID env and clean up zombie state files

const fs = require("fs");
const { cleanupZombies, createInitialState, writeState, readState } = require("./lib/workflow-state");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

let sessionId;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id;
} catch (e) {
  // Fail-open: malformed input — continue without setting session ID
}

// Write CLAUDE_SESSION_ID to env file if available (KEY=VALUE format, no export prefix)
if (sessionId && process.env.CLAUDE_ENV_FILE) {
  try {
    fs.appendFileSync(
      process.env.CLAUDE_ENV_FILE,
      `CLAUDE_SESSION_ID=${sessionId}\n`,
      "utf8"
    );
  } catch (e) {
    // Fail-open
  }
}

// Create initial state file if session_id and CLAUDE_PROJECT_DIR are available
if (sessionId && process.env.CLAUDE_PROJECT_DIR) {
  try {
    const repoDir = process.env.CLAUDE_PROJECT_DIR;
    // Only create if state file does not already exist (idempotent)
    const existing = readState(repoDir, sessionId);
    if (!existing) {
      const state = createInitialState(sessionId);
      writeState(repoDir, sessionId, state);
    }
  } catch (e) {
    // Fail-open: non-git dir, permission error, etc. — do not crash SessionStart
  }
}

// Clean up zombie state files (older than 7 days)
try {
  cleanupZombies(process.env.CLAUDE_PROJECT_DIR || process.cwd(), 7);
} catch (e) {
  // Fail-open
}

// SessionStart hooks must output valid JSON
console.log("{}");
