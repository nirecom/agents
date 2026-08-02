// hooks/lib/tool-command-text.js
// SSOT (CPR-2) for "what shell text is this tool call about to execute?".
//
// Claude Code ships THREE command-executing tools and they do NOT agree on the
// payload shape:
//
//   Bash           -> tool_input.command   (string)
//   runInTerminal  -> tool_input.command   (string)
//   runCommands    -> tool_input.commands  (ARRAY of strings)
//
// Every PreToolUse hook that scans a command therefore has to normalize, and
// before #1780 each one open-coded it — hooks/enforce-system-ops.js handled the
// array while hooks/block-off-clearance-write/dispatch.js and
// hooks/supervisor-off-proposal-shim.js read `.command` only, so a runCommands
// call sailed past them with `undefined`. That is a silent full bypass, not a
// degraded check.
//
// The joiner is "\n" because every consumer feeds the result to a shell-command
// scanner: newline is a statement separator in both POSIX sh and PowerShell, so
// commands[1] is scanned as its own statement rather than being glued onto the
// tail of commands[0]. Joining with "; " would also work for sh but would
// corrupt PowerShell here-strings/comments; "\n" is the only separator that is
// a separator in both.
//
// Never returns null/undefined — callers branch on emptiness, and a non-string
// payload must degrade to "" rather than to the literal "undefined" (which
// contains no protected name and would read as "scanned and clean").
"use strict";

// Tools whose payload this module knows how to read. Exported so hooks can gate
// on ONE list instead of repeating a three-way `!==` chain that drifts.
const COMMAND_TOOL_NAMES = ["Bash", "runInTerminal", "runCommands"];

function isCommandTool(toolName) {
  return COMMAND_TOOL_NAMES.indexOf(toolName) !== -1;
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
// The same payload, kept SEPARATE instead of joined (CPR-3). Two different
// questions are being asked of a tool call and they need different shapes:
//
//   "does any protected path appear anywhere in what will run?"  -> commandTextOf
//   "is THIS command an exact sentinel emission?"                -> commandListOf
//
// hooks/lib/sentinel-patterns.js anchors every pattern with ^...$ and no `m`
// flag, so a sentinel sitting in commands[1] can never match the joined text —
// it must be matched against its own element. Empty elements are dropped so
// callers can treat an empty list as "nothing to adjudicate".
function commandListOf(toolName, toolInput) {
  const input = toolInput && typeof toolInput === "object" ? toolInput : {};
  if (toolName === "runCommands" && Array.isArray(input.commands)) {
    return input.commands.map((c) => String(c == null ? "" : c)).filter((c) => c !== "");
  }
  const text = commandTextOf(toolName, input);
  return text ? [text] : [];
}

module.exports = { COMMAND_TOOL_NAMES, isCommandTool, commandTextOf, commandListOf };
