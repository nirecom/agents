#!/usr/bin/env node
"use strict";
// Claude Code UserPromptSubmit / PostToolUse (matcher "") / Stop hook (#2594): ask the main
// conversation to update <rootSid>-session-progress.md when a step completed (4a), the transcript grew
// (4c) or a compaction happened (4d). Silent outside the workflow active period and for
// subagent calls. The evaluation lives in hooks/progress-nudge/; this file only dispatches.
// Design: docs/architecture/claude-code/progress-file.md.
//
// Fail-open: any error → emit {} and exit 0.

const { readHookInput } = require("./lib/read-stdin");

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
  const { isSubagentCall } = require("./lib/subagent-detect");
  if (isSubagentCall(input)) return quiet();
  const event = typeof input.hook_event_name === "string" ? input.hook_event_name : "UserPromptSubmit";
  if (event === "Stop" && input.stop_hook_active === true) return quiet();
  const tool = typeof input.tool_name === "string" ? input.tool_name : null;
  const now = Date.now();

  const { isCommandTool } = require("./lib/tool-command-text");
  const full = event === "Stop" || (event === "PostToolUse" && (isCommandTool(tool) || tool === "Agent" || tool === "Task"));
  if (!full && !require("./progress-nudge/light").needsFullPath(sid, transcriptPath, now)) return quiet();

  const { isWorkflowActivePeriod } = require("./lib/workflow-active-period");
  if (!isWorkflowActivePeriod(sid)) return quiet();

  const context = require("./progress-nudge/evaluate").evaluate({ sid, event, tool, transcriptPath, now });
  if (!context) return quiet();
  const { withConvLang } = require("./lib/conv-lang");
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: withConvLang(context) } })}\n`);
}

try {
  main();
} catch (_e) {
  quiet();
}
