#!/usr/bin/env node
"use strict";
// UserPromptSubmit hook: record one turn id per user prompt for plan-sync (#2768).
// The previous turn file is removed first, so a failed write leaves no turn rather than a stale one.
// Fail-open throughout: a missing turn only makes plan-sync append instead of replace.

const fs = require("fs");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("user-prompt-submit-turn-id", r, "turn id skipped") + "\n");
    } catch (_) {}
    return;
  }
  const input = r.input;
  if (!input || typeof input !== "object" || Array.isArray(input)) return;
  const sid = input.session_id;
  if (typeof sid !== "string" || !SID_RE.test(sid)) return;

  const { controlPath } = require("./workflow-state/state-io/control-dir");
  const T = require("./lib/prompt-turn-id");
  try {
    fs.unlinkSync(controlPath(sid, T.PROMPT_TURN_FILE));
  } catch (_) { /* a locked or missing file must not stop the write below, which replaces it */ }
  T.writePromptTurn(sid);
}

if (require.main === module) {
  try {
    main();
  } catch (_) { /* fail-open: never break the user's prompt */ }
  process.stdout.write("{}\n");
  process.exit(0);
}

module.exports = { main };
