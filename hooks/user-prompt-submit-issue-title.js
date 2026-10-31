#!/usr/bin/env node
"use strict";
// UserPromptSubmit hook: name the session after its issues (#299). Logic: ./user-prompt-submit-issue-title/.
// Emits {hookSpecificOutput:{hookEventName,sessionTitle}} or {}; always exits 0.

const fs = require("fs");
const T = require("./user-prompt-submit-issue-title/title");

if (require.main === module) {
  let out = "{}\n";
  try {
    const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
    const r = readHookInput();
    if (r.kind !== "ok") {
      fs.writeSync(2, readFailOpenDiagnostic("user-prompt-submit-issue-title", r, "session title skipped") + "\n");
    } else {
      const title = T.run(r.input, {});
      if (typeof title === "string") {
        out = JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", sessionTitle: title } }) + "\n";
      }
    }
  } catch (_) { /* fail-open: never break the user's prompt */ }
  process.stdout.write(out);
  process.exit(0);
}

module.exports = T;
