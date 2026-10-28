#!/usr/bin/env node
"use strict";
// Claude Code UserPromptSubmit / PostToolUse (matcher "") hook (#2731 R1): re-inject the CONV_LANG
// directive during long autonomous stretches. PostToolUse emits it once the transcript has grown by
// REINJECT_BYTES since the baseline; UserPromptSubmit only resets the baseline, because
// lang-inject.js already carries that turn's directive. Silent for subagent calls and a no-op
// CONV_LANG. Baseline: <WORKFLOW_STATE_DIR>/<sid>.control/conv-lang-reinject.json.
// Frequency and its reasons: docs/architecture/claude-code/lang-directives.md.
//
// Fail-open: any error → emit {} and exit 0.

const fs = require("fs");
const { readHookInput } = require("./lib/read-stdin");

const REINJECT_BYTES = 128 * 1024;
const SIDECAR = "conv-lang-reinject.json";

function quiet() {
  process.stdout.write("{}\n");
}

function main() {
  const r = readHookInput();
  if (r.kind !== "ok") return quiet();
  const input = r.input;
  if (!input || typeof input !== "object") return quiet();
  const sid = input.session_id;
  const transcriptPath = input.transcript_path;
  if (typeof sid !== "string" || !sid || typeof transcriptPath !== "string" || !transcriptPath) return quiet();
  if (require("./lib/subagent-detect").isSubagentCall(input)) return quiet();
  const directive = require("./lib/conv-lang").getConvLangInjection();
  if (!directive) return quiet();

  const event = input.hook_event_name;
  if (event !== "UserPromptSubmit" && event !== "PostToolUse") return quiet();
  const size = fs.statSync(transcriptPath).size;
  const { readSidecar, writeSidecar } = require("./lib/handoff-sidecar");
  const baseline = (readSidecar(sid, SIDECAR) || {}).baselineBytes;
  const known = typeof baseline === "number" && Number.isFinite(baseline);

  if (event === "UserPromptSubmit" || !known || size < baseline) {
    writeSidecar(sid, SIDECAR, { baselineBytes: size });
    return quiet();
  }
  if (size - baseline < REINJECT_BYTES) return quiet();
  if (!writeSidecar(sid, SIDECAR, { baselineBytes: size })) return quiet();
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: directive } })}\n`);
}

try {
  main();
} catch (_e) {
  quiet();
}
