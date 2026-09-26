"use strict";
// skills/worktree-end/scripts/resolve-dir-expand.js
//
// Resolves whether dir_expand should be true for the current session.
// Self-resolves session id (never relies on CLAUDE_SESSION_ID alone —
// that env var is absent in WE-9 Bash subprocess contexts; #1082).
// Exits 0; prints "true" or "false" to stdout.

const { resolveSessionId } = require("../../../hooks/workflow-state/session-id");
const { isVerbosePromptSession } = require("../../../hooks/lib/verbose-prompt");

const args = process.argv.slice(2);
let sessionFromArg = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--session" && args[i + 1]) {
    sessionFromArg = args[i + 1];
    break;
  }
}

let sessionId = null;
try {
  sessionId = resolveSessionId({ sessionIdFromInput: sessionFromArg || undefined });
} catch (_) {
  sessionId = null;
}

const result = sessionId ? isVerbosePromptSession(sessionId) : false;
process.stdout.write(result ? "true" : "false");
process.exit(0);
