// hooks/lib/tool-command-text.js
// SSOT (CPR-SSOT) for "what shell text is this tool call about to execute?".
// Payload shapes: Bash / runInTerminal / PowerShell -> tool_input.command (string);
// runCommands -> tool_input.commands (ARRAY). Before #1780 hooks open-coded `.command`,
// so a runCommands call sailed past them with `undefined` — a silent full bypass.
// The joiner is "\n": a statement separator in both POSIX sh and PowerShell ("; " would
// corrupt PowerShell here-strings/comments), so commands[1] is scanned as its own statement.
// Never returns null/undefined — a non-string payload degrades to "", never to the literal
// "undefined" (which would read as "scanned and clean").
"use strict";

// Tools whose payload this module knows how to read. Exported so hooks can gate
// on ONE list instead of repeating a three-way `!==` chain that drifts.
const COMMAND_TOOL_NAMES = ["Bash", "runInTerminal", "runCommands"];

function isCommandTool(toolName) {
  return COMMAND_TOOL_NAMES.indexOf(toolName) !== -1;
}

// Kept out of COMMAND_TOOL_NAMES (the settings.json matcher contract in write-tools.js);
// a hook that scans PowerShell script text opts in explicitly.
const POWERSHELL_TOOL_NAMES = ["PowerShell"];

function isPowerShellTool(toolName) {
  return POWERSHELL_TOOL_NAMES.indexOf(toolName) !== -1;
}

// commandTextOf(toolName, toolInput) -> string
// Mirrors hooks/enforce-system-ops.js's long-standing contract exactly:
// runCommands joins its array with "\n"; a non-array `commands` degrades via
// String(); every other tool reads `.command`. Missing/malformed input -> "".
function commandTextOf(toolName, toolInput) {
  const input = toolInput && typeof toolInput === "object" ? toolInput : {};
  if (toolName === "runCommands") {
    const cmds = input.commands;
    if (Array.isArray(cmds)) return cmds.map((c) => String(c == null ? "" : c)).join("\n");
    return String(cmds == null ? "" : cmds);
  }
  const cmd = input.command;
  return typeof cmd === "string" ? cmd : String(cmd == null ? "" : cmd);
}

// commandListOf(toolName, toolInput) -> string[]
// The same payload kept SEPARATE instead of joined (CPR-SC): commandTextOf answers "does a
// protected path appear anywhere?", this answers "is THIS command an exact sentinel emission?".
// hooks/lib/sentinel-patterns.js anchors every pattern with ^...$ and no `m` flag, so a
// sentinel in commands[1] must be matched against its own element. Empty elements are
// dropped so an empty list means "nothing to adjudicate".
function commandListOf(toolName, toolInput) {
  const input = toolInput && typeof toolInput === "object" ? toolInput : {};
  if (toolName === "runCommands" && Array.isArray(input.commands)) {
    return input.commands.map((c) => String(c == null ? "" : c)).filter((c) => c !== "");
  }
  const text = commandTextOf(toolName, input);
  return text ? [text] : [];
}

module.exports = {
  COMMAND_TOOL_NAMES,
  POWERSHELL_TOOL_NAMES,
  isCommandTool,
  isPowerShellTool,
  commandTextOf,
  commandListOf,
};
