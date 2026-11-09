#!/usr/bin/env node
"use strict";
// PreToolUse(AskUserQuestion) hook (#2764): the dialog carries metadata.source=<dialog ID>. When
// the classification table rates the ID low, the session is on a step the ID declares, and Jev is
// confident which option the user would pick for every question, answer it for the user (allow +
// updatedInput: the original input plus the answers). Otherwise print nothing, so the dialog
// reaches the user. Every call identified as AskUserQuestion leaves one route record
// (askuser-routes.jsonl). Fail-open on every error.

// Taken before anything loads load-env, as every Jev entrypoint does (test-overrides.js).
const JEV_OVERRIDES = require("./lib/jev/test-overrides").captureTestOverrides(process.env);

async function main() {
  const r = require("./lib/read-stdin").readHookInput();
  if (r.kind !== "ok" || !r.input || r.input.tool_name !== "AskUserQuestion") return;
  const input = r.input;
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  // Only the hook input's own session_id counts: a fallback (transcript name, env) would route a
  // call without one past no-sid with a guessed session.
  let sid = null;
  if (typeof input.session_id === "string" && input.session_id) {
    try {
      sid = require("./workflow-state").resolveSessionId({
        sessionIdFromInput: input.session_id,
        transcriptPath: input.transcript_path,
      });
    } catch (_e) { sid = null; }
  }
  const d = await require("./lib/askuser-jev-decide").decide({
    sid, transcriptPath: input.transcript_path, questions: toolInput.questions, metadata: toolInput.metadata,
    overrides: JEV_OVERRIDES,
  });
  require("./lib/askuser-route-log").recordRoute({
    sessionId: sid, dialogId: d.dialogId, route: d.route, step: d.step, jevCalled: d.jevCalled,
  });
  if (d.route !== "answered" || !d.answers) return;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Jev answered the dialog from the conversation (pre-tool-use-askuser-jev.js)",
      updatedInput: Object.assign({}, toolInput, { answers: d.answers }),
    },
  }) + "\n");
}

main().then(() => process.exit(0), () => process.exit(0));
