#!/usr/bin/env node
"use strict";
// Claude Code UserPromptSubmit hook: nudge an emergency handoff flush when the
// transcript has grown far past the last recorded micro-state.
//
// Fail-open: any error → emit {} and exit 0.

const fs = require("fs");
const { computePressureSignal } = require("./lib/handoff-pressure");

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

function handoffMtimeFor(sessionId) {
  try {
    const { getHandoffPath } = require("./lib/handoff-artifact");
    return fs.statSync(getHandoffPath(sessionId)).mtimeMs;
  } catch (e) {
    return null;
  }
}

function main() {
  let input = null;
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    console.log("{}");
    return;
  }
  if (!input || typeof input !== "object") {
    console.log("{}");
    return;
  }
  const signal = computePressureSignal({
    transcriptPath: input.transcript_path,
    handoffMtime: handoffMtimeFor(input.session_id),
  });
  if (!signal.shouldNudge) {
    console.log("{}");
    return;
  }
  const kb = Math.round(signal.bytes / 1024);
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext:
        `[handoff pressure] This session's transcript has grown to ~${kb}KB since the last handoff write. ` +
        "Follow rules/handoff-emergency-flush.md now: record the micro-state you would lose to a compaction " +
        'via `node "$AGENTS_CONFIG_DIR/bin/workflow/handoff-append"`, then continue.',
    },
  }));
}

try {
  main();
} catch (_e) {
  console.log("{}");
}
