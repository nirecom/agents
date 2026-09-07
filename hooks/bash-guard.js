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
  if (verdict && verdict.verdict === "deny") {
    console.log(JSON.stringify({ decision: "block", reason: verdict.message }));
  } else {
    console.log(JSON.stringify({ decision: "approve" }));
  }
  process.exit(0);
}

if (require.main === module) main();
