#!/usr/bin/env node
// Claude Code SessionStart hook: set CLAUDE_SESSION_ID env and clean up zombie state files

const fs = require("fs");
const { cleanupZombies } = require("./lib/workflow-state");

// --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
const DEBUG_LOG = process.env.TEMP
  ? `${process.env.TEMP}/session-start-debug.log`
  : "/tmp/session-start-debug.log";

function debugLog(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`, "utf8");
  } catch (e) {}
}
// --- END temporary: CLAUDE_ENV_FILE debug logging ---

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
  // --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
  debugLog(`parsed session_id: ${sessionId}`);
  // --- END temporary: CLAUDE_ENV_FILE debug logging ---
} catch (e) {
  // --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
  debugLog(`JSON parse failed: ${e}`);
  // --- END temporary: CLAUDE_ENV_FILE debug logging ---
  // Fail-open: malformed input — continue without setting session ID
}

// Write CLAUDE_SESSION_ID to env file if available (KEY=VALUE format, no export prefix)
// --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
debugLog(`CLAUDE_ENV_FILE=${process.env.CLAUDE_ENV_FILE || "(not set)"}`);
// --- END temporary: CLAUDE_ENV_FILE debug logging ---
if (sessionId && process.env.CLAUDE_ENV_FILE) {
  try {
    fs.appendFileSync(
      process.env.CLAUDE_ENV_FILE,
      `CLAUDE_SESSION_ID=${sessionId}\n`,
      "utf8"
    );
    // --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
    debugLog("wrote CLAUDE_SESSION_ID to CLAUDE_ENV_FILE");
    // --- END temporary: CLAUDE_ENV_FILE debug logging ---
  } catch (e) {
    // --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
    debugLog(`write failed: ${e}`);
    // --- END temporary: CLAUDE_ENV_FILE debug logging ---
    // Fail-open
  }
// --- BEGIN temporary: CLAUDE_ENV_FILE debug logging ---
} else {
  debugLog(`skip write: sessionId=${!!sessionId} CLAUDE_ENV_FILE=${!!process.env.CLAUDE_ENV_FILE}`);
// --- END temporary: CLAUDE_ENV_FILE debug logging ---
}

// Clean up zombie state files (older than 7 days)
try {
  cleanupZombies(process.env.HOOK_CWD || process.cwd(), 7);
} catch (e) {
  // Fail-open
}

// SessionStart hooks must output valid JSON
console.log("{}");
