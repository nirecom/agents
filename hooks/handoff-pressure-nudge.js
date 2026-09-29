#!/usr/bin/env node
"use strict";
// Claude Code UserPromptSubmit hook: ask for a handoff omission check (C/D/F
// facts not yet recorded) once enough work has accumulated since the last
// check. Silent outside the workflow active period — no workflow to resume.
//
// Fail-open: any error → emit {} and exit 0.

const fs = require("fs");
const { computePressureSignal } = require("./lib/handoff-pressure");
const { isWorkflowActivePeriod } = require("./lib/workflow-active-period");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    for (;;) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) { /* fail-open */ }
  return Buffer.concat(chunks).toString("utf8");
}

function main() {
  let input = null;
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    console.log("{}");
    return;
  }
  if (!input || typeof input !== "object" || !isWorkflowActivePeriod(input.session_id)) {
    console.log("{}");
    return;
  }
  const signal = computePressureSignal({
    sid: input.session_id,
    transcriptPath: input.transcript_path,
    now: Date.now(),
  });
  if (!signal.shouldNudge) {
    console.log("{}");
    return;
  }
  const kb = Math.round(signal.bytesSince / 1024);
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext:
        `[handoff check] ~${kb}KB of work since the last check (trigger: ${signal.trigger}). ` +
        'Per rules/handoff-emergency-flush.md "What to record", check for C/D/F facts not yet recorded; ' +
        "if there are none, write nothing and continue.",
    },
  }));
}

try {
  main();
} catch (_e) {
  console.log("{}");
}
