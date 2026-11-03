"use strict";
// Fabricated transcript records for tests/hooks/feature-2877-sentinel-receipt-backstop.js. The
// shapes copy what Claude Code writes (assistant tool_use, user tool_result with is_error, and the
// hook_cancelled attachment of tests/hooks/feature-2676-hook-cancel-notice/transcript.js, here on
// PostToolUse); every value is made up.

const SENTINEL = 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"';
const MARK_COMMAND = 'node "C:/example/agents/hooks/workflow-mark.js"';

let counter = 0;
const nextUuid = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
const common = (sid) => ({
  parentUuid: nextUuid(), isSidechain: false, uuid: nextUuid(), timestamp: "2026-01-01T00:00:00.000Z",
  userType: "external", entrypoint: "sdk-cli", cwd: "C:/example/work", sessionId: sid,
  version: "0.0.0-fixture", gitBranch: "main",
});

const userPrompt = (sid, text) => ({ ...common(sid), type: "user", message: { role: "user", content: text } });
const assistantText = (sid, text) => ({ ...common(sid), type: "assistant",
  message: { role: "assistant", content: [{ type: "text", text }] } });
const toolUse = (sid, id, command) => ({ ...common(sid), type: "assistant",
  message: { role: "assistant", content: [{ type: "tool_use", id, name: "Bash", input: { command, description: "fixture" } }] } });
// toolResult(sid, id, {isError, text}) — is_error true is what a PreToolUse or permission deny writes.
const toolResult = (sid, id, o = {}) => {
  const item = { type: "tool_result", tool_use_id: id, content: o.text || "" };
  if (o.isError) item.is_error = true;
  return { ...common(sid), type: "user", message: { role: "user", content: [item] } };
};
// postToolUseCancel(sid, id, event, {timedOut}) — event defaults to PostToolUse and timedOut to true;
// another event, or timedOut false (the user's interrupt), is a negative case.
const postToolUseCancel = (sid, id, event = "PostToolUse", o = {}) => ({
  ...common(sid), type: "attachment",
  attachment: {
    type: "hook_cancelled", hookName: `${event}:Bash`, toolUseID: id, hookEvent: event,
    command: MARK_COMMAND, durationMs: 5100, timedOut: o.timedOut !== false, timeoutMs: 5000,
  },
});

// call(sid, id, command, resultOpts) -> the tool_use and its tool_result.
const call = (sid, id, command, o) => [toolUse(sid, id, command), toolResult(sid, id, o)];
const toText = (records) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

module.exports = { SENTINEL, MARK_COMMAND, userPrompt, assistantText, toolUse, toolResult, postToolUseCancel, call, toText };
