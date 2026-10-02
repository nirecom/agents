#!/usr/bin/env node
"use strict";
// hooks/bash-guard.js — PreToolUse (matcher: Bash) entrypoint for the command-line
// issuance guard (#2134). Dispatch + re-export only; the verdict lives in
// ./bash-guard/judge.js and the forbidden set in ./bash-guard/forbidden-literals.js.
//
// The matcher is the bare "Bash" on purpose: runInTerminal / runCommands can drive pwsh,
// where a backtick is a line continuation — reading that with a bash parser would produce
// confident false denials. Unreadable stdin denies (fail-close); malformed JSON produces
// NO envelope (one stderr diagnostic) rather than a verdict invented from nothing.
const fs = require("fs");
const { judgeBashCommand } = require("./bash-guard/judge");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "bash-guard";

module.exports = { judgeBashCommand };

// Verdict -> stdout envelope.
// G-b=(b2) fallback form (detail.md:96): legacy {decision:"approve"} bypasses the
// permission prompt; passThrough and notify must output the same to preserve current
// behaviour. A silent passThrough would add prompts for every unlisted command.
const ENVELOPES = Object.freeze({
  deny: (v) => ({ decision: "block", reason: v.message }),
  notify: (v) => ({
    decision: "approve",
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
  passThrough: () => ({ decision: "approve" }),
});

function main() {
  const r = readHookInput();
  if (r.kind === "read-error") {
    console.log(JSON.stringify(ENVELOPES.deny({ message: readFailureReason(HOOK_NAME, r.error) })));
    process.exit(0);
  }
  if (r.kind === "json-invalid") {
    try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
    process.exit(0);
  }
  const input = r.input;
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
