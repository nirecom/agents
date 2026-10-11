#!/usr/bin/env node
// PreToolUse hook (matcher SendUserFile): deny SendUserFile. A plan reaches the user as the
// plan-link line written in the response text (its blob URL with the local path, or the local
// path with a reason word); sending the file would copy the plan out of the plans dir past the
// plan-sync send rules. Fail-open: any other tool, or unreadable / non-object stdin, passes
// through with no output.
"use strict";

const { readHookInput } = require("./lib/read-stdin");

function denyReason() {
  let command = "bin/plan-link";
  try { command = require("./lib/plan-link").PLAN_LINK_COMMAND; } catch (_) { /* keep the short name */ }
  return "SendUserFile is disabled here: show a plan by writing its plan-link line (the URL, or the local path " +
    `when there is no URL) in your response text — run ${command} to print it. (Hook: block-send-user-file.js)`;
}

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
        permissionDecisionReason: denyReason(),
      },
    }));
  }
  process.exit(0);
}

module.exports = { denyReason };
