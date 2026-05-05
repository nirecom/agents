#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: detect post-push workflow boundary.
//
// Purpose: When a `git push` completes successfully, workflow-mark.js records
// the pushed HEAD SHA as `last_pushed_sha` in the session's workflow state.
// On the next user prompt, this hook checks whether HEAD still equals
// last_pushed_sha. If so, the user is likely starting a new task — reset the
// workflow to `branching_decision` (force fresh branch/worktree creation).
//
// This is the "push milestone" detector. It does NOT participate in
// sibling-session detection (that responsibility was removed in favor of
// AGENT_AUTO_BRANCH enforcement via auto-branch-guard.js).

const fs = require("fs");
const { execSync } = require("child_process");
const {
  resolveSessionId,
  readState,
  markStep,
  clearLastPushedSha,
} = require("./lib/workflow-state");
const { resolveRepoCwd } = require("./lib/path-normalize");

// Load $AGENTS_CONFIG_DIR/.env into process.env (existing env wins)
try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

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
let parsedInput = null;
try {
  parsedInput = JSON.parse(readStdin());
  sessionId = parsedInput.session_id || resolveSessionId();
} catch (e) {
  sessionId = resolveSessionId();
}

if (!sessionId) {
  console.log(JSON.stringify({}));
  process.exit(0);
}

let additionalContext;

try {
  const state = readState(sessionId);
  if (state && state.last_pushed_sha) {
    // Use the same cwd resolution as workflow-mark.js so write/read see the same repo.
    // Note: parsedInput is the UserPromptSubmit stdin (no `command` field).
    const repoCwd = resolveRepoCwd({
      input: parsedInput,
      stateCwd: state.cwd,
    });
    let head = null;
    try {
      head = execSync("git rev-parse HEAD", { cwd: repoCwd, encoding: "utf8", timeout: 2000 }).trim();
    } catch (e) {
      head = null;
    }
    if (head && head === state.last_pushed_sha) {
      try { markStep(sessionId, "branching_decision", "pending"); } catch (e) {}
      try { clearLastPushedSha(sessionId); } catch (e) {}
      additionalContext =
        "Push boundary detected: HEAD matches last pushed SHA.\n" +
        "Workflow reset to branching_decision — re-evaluate branch/worktree before next commit.";
    }
  }
} catch (e) {
  // Fail-open
}

// UserPromptSubmit hook contract requires nesting additionalContext under
// hookSpecificOutput (see Claude Code docs / scan-inbound.js).
const out = additionalContext
  ? { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext } }
  : {};
console.log(JSON.stringify(out));
