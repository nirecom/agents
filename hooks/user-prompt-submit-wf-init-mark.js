#!/usr/bin/env node
"use strict";
// UserPromptSubmit hook: record workflow_init in_progress when the user types
// /workflow-init (#1633). A typed slash command expands to prompt text, never a
// Skill tool call, so hooks/postuse-step-in-flight-mark.js cannot see it.
// Fail-open throughout: a missed mark only delays when the WF reads as begun.

const fs = require("fs");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("user-prompt-submit-wf-init-mark", r, "wf-init mark skipped") + "\n");
    } catch (_) {}
    return;
  }
  const input = r.input;
  if (!input || typeof input !== "object" || Array.isArray(input)) return;
  if (typeof input.session_id !== "string" || !input.session_id) return;

  const policy = require("./lib/step-in-flight-policy");
  if (!policy.promptInvokesWfInit(input.prompt)) return;

  const { resolveSessionId } = require("./workflow-state");
  const sid = resolveSessionId({
    sessionIdFromInput: input.session_id,
    transcriptPath: typeof input.transcript_path === "string" ? input.transcript_path : "",
  });
  if (!sid) return;

  require("./lib/wf-init-begun-mark").markWorkflowInitBegun(sid);
}

if (require.main === module) {
  try {
    main();
  } catch (_) { /* fail-open: never break the user's prompt */ }
  process.stdout.write("{}\n");
  process.exit(0);
}

module.exports = { main };
