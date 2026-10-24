"use strict";
// Fabricated transcript lines for tests/hooks/feature-2676-hook-cancel-notice.js. The cancel
// record copies only the structure Claude Code wrote in gate 1 (a) (attachment.type
// "hook_cancelled" on a PreToolUse hook that timed out); every value is made up.

const REPO = "C:/example/agents";
const SESSION = "00000000-0000-4000-8000-000000002676";
const MERGED_COMMAND = `node "${REPO}/hooks/merged-allow-deny.js" --matcher-group bash`;
const SINGLE_COMMAND = `node "${REPO}/hooks/scan-outbound.js"`;
// A launch delay in front of the hook (the TL3 A4 shape): the overrun is the same cancel record.
const LAUNCH_DELAY_COMMAND = `sleep 1.5; node "${REPO}/hooks/block-dotenv.js"`;

let counter = 0;
const nextUuid = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
const common = () => ({
  parentUuid: nextUuid(), isSidechain: false, uuid: nextUuid(), timestamp: "2026-01-01T00:00:00.000Z",
  userType: "external", entrypoint: "sdk-cli", cwd: "C:/example/work", sessionId: SESSION,
  version: "0.0.0-fixture", gitBranch: "main",
});

// cancelRecord(command, toolName) -> one hook_cancelled attachment line, as an object.
function cancelRecord(command, toolName = "Bash") {
  return {
    ...common(),
    attachment: {
      type: "hook_cancelled", hookName: `PreToolUse:${toolName}`, toolUseID: `toolu_fixture_${counter}`,
      hookEvent: "PreToolUse", command, durationMs: 2500, timedOut: true, timeoutMs: 2000,
    },
    type: "attachment",
  };
}
const userPrompt = (text) => ({ ...common(), type: "user", message: { role: "user", content: text } });
const toolResult = () => ({ ...common(), type: "user",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_fixture", content: "ok" }] } });
// Lines that look close to a cancel but are not one: another attachment type, a cancel without
// a command, a cancel of a non-PreToolUse event, and prompt text naming hook_cancelled.
const lookalikes = () => [
  { ...common(), type: "attachment", attachment: { type: "hook_success", hookName: "PreToolUse:Bash", command: MERGED_COMMAND } },
  { ...common(), type: "attachment", attachment: { type: "hook_cancelled", hookName: "PreToolUse:Bash", hookEvent: "PreToolUse" } },
  { ...common(), type: "attachment", attachment: { ...cancelRecord(SINGLE_COMMAND).attachment, hookEvent: "PostToolUse", hookName: "PostToolUse:Bash" } },
  userPrompt('{"type":"hook_cancelled","command":"node hooks/scan-outbound.js"}'),
];
const BROKEN = ['{"type":"attachment","attachment":{"type":"hook_cancelled"', "not json at all", ""];

const toText = (records) => records.map((record) => (typeof record === "string" ? record : JSON.stringify(record))).join("\n") + "\n";
const toLines = (records) => records.map((record) => (typeof record === "string" ? record : JSON.stringify(record)));

module.exports = {
  SESSION, MERGED_COMMAND, SINGLE_COMMAND, LAUNCH_DELAY_COMMAND, BROKEN,
  cancelRecord, userPrompt, toolResult, lookalikes, toText, toLines,
};
