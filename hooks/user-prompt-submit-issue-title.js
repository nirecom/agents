#!/usr/bin/env node
"use strict";
// UserPromptSubmit hook: run the PM writer (#2941), then name the session after its issues (#299).
// Logic: ./user-prompt-submit-issue-title/. Emits {decision:"block", reason} for a refused PM command,
// else {hookSpecificOutput:{hookEventName, sessionTitle?, additionalContext?}, systemMessage?} or {};
// systemMessage carries the writer's one-sentence notice for the user. Always exits 0.

const fs = require("fs");
const T = require("./user-prompt-submit-issue-title/title");

function outputOf(r) {
  if (r.block) return { decision: "block", reason: r.block };
  const h = { hookEventName: "UserPromptSubmit" };
  if (typeof r.title === "string") h.sessionTitle = r.title;
  if (r.context) h.additionalContext = r.context;
  const out = Object.keys(h).length > 1 ? { hookSpecificOutput: h } : {};
  if (typeof r.notice === "string" && r.notice) out.systemMessage = r.notice;
  return out;
}

if (require.main === module) {
  let out = "{}\n";
  try {
    const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
    const r = readHookInput();
    if (r.kind !== "ok") {
      fs.writeSync(2, readFailOpenDiagnostic("user-prompt-submit-issue-title", r, "session title skipped") + "\n");
    } else {
      out = JSON.stringify(outputOf(T.respond(r.input, {}))) + "\n";
    }
  } catch (_) { /* fail-open: never break the user's prompt */ }
  process.stdout.write(out);
  process.exit(0);
}

module.exports = Object.assign({}, T, { run: (input, deps) => T.respond(input, deps).title });
