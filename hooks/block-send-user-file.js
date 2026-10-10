#!/usr/bin/env node
// PreToolUse hook (matcher SendUserFile): deny SendUserFile. A plan reaches the user as its
// GitHub blob URL written in the response text (bin/plan-link prints it); sending the local
// file instead would expose the private plans dir and bypass plan-sync. Fail-open: any other
// tool, or unreadable / non-object stdin, passes through with no output.
"use strict";

const { readHookInput } = require("./lib/read-stdin");

const DENY_REASON = "SendUserFile is disabled here: show a plan by writing its GitHub blob URL in your response text " +
  '(run node "$AGENTS_CONFIG_DIR/bin/plan-link" to print it), never by sending the file. (Hook: block-send-user-file.js)';

if (require.main === module) {
  let input = null;
  try {
    const r = readHookInput();
    if (r.kind === "ok" && r.input && typeof r.input === "object" && !Array.isArray(r.input)) input = r.input;
  } catch (_) { /* fail-open */ }
  if (input && input.tool_name === "SendUserFile") {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: DENY_REASON,
      },
    }));
  }
  process.exit(0);
}

module.exports = { DENY_REASON };
