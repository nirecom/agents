#!/usr/bin/env node
"use strict";
// hooks/bash-guard.js — PreToolUse (matcher: Bash) entrypoint for the command-line
// issuance guard (#2134). Dispatch + re-export only; the verdict lives in
// ./bash-guard/judge.js and the forbidden set in ./bash-guard/forbidden-literals.js.
//
// The matcher is the bare "Bash" on purpose: runInTerminal / runCommands can drive pwsh,
// where a backtick is a line continuation — reading that with a bash parser would produce
// confident false denials. Fail-open reaches the process boundary: stdin this hook cannot
// parse produces NO envelope at all rather than a verdict invented from nothing.
const fs = require("fs");
const { judgeBashCommand } = require("./bash-guard/judge");

module.exports = { judgeBashCommand };

// Verdict -> stdout envelope. passThrough writes nothing, so the host's own permission
// rules decide; only allow may carry permissionDecision "allow".
const ENVELOPES = Object.freeze({
  deny: (v) => ({ decision: "block", reason: v.message }),
  notify: (v) => ({
    systemMessage: v.message,
    hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: v.message },
  }),
  allow: (v) => ({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "bash-guard " + v.code,
    },
  }),
  passThrough: () => null,
});

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) { /* a closed or unreadable stdin reads as empty */ }
  return Buffer.concat(chunks).toString("utf8");
}

function main() {
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch (_e) {
    process.exit(0); // unparseable payload: say nothing, decide nothing
  }
  let verdict;
  try {
    verdict = judgeBashCommand(input);
  } catch (_e) {
    process.exit(0);
  }
  const build = verdict && Object.prototype.hasOwnProperty.call(ENVELOPES, verdict.verdict)
    ? ENVELOPES[verdict.verdict]
    : ENVELOPES.passThrough;
  const envelope = build(verdict);
  if (envelope) console.log(JSON.stringify(envelope));
  process.exit(0);
}

if (require.main === module) main();
