// hooks/lib/write-tools.js
// SSOT (CPR-2) for the WRITE-CAPABLE TOOL CLASSES that PreToolUse hooks guard,
// and for the payload shapes each class uses to name its target.
//
// Two classes, and every guard needs both (CPR-5 — a guard that covers one
// member of a class and not its siblings is a bypass, not a partial guard):
//
//   edit-write class : Edit, Write, MultiEdit, editFiles, NotebookEdit
//                      target(s) under file_path / path / notebook_path, either
//                      at the top level or per-entry in an `edits[]` array
//   command class    : Bash, runInTerminal, runCommands
//                      (see hooks/lib/tool-command-text.js for its payload)
//
// #1780 round-4 H-2: hooks/enforce-worktree.js recognized only the original
// four (Bash/Edit/Write/MultiEdit) and settings.json registered it on the same
// four, so editFiles / NotebookEdit / runInTerminal / runCommands bypassed
// main-worktree and protected-branch enforcement outright.
//
// TOOL_MATCHER is the settings.json `matcher` string for a hook that guards
// every write path. Keeping it here means the registration and the runtime
// branch cannot drift apart silently — but settings.json is data, so the value
// must be kept in sync by hand; tests/ assert the two agree.
"use strict";

const { COMMAND_TOOL_NAMES, isCommandTool, commandTextOf, commandListOf } = require("./tool-command-text");

const EDIT_WRITE_TOOL_NAMES = ["Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"];

function isEditWriteTool(toolName) {
  return EDIT_WRITE_TOOL_NAMES.indexOf(toolName) !== -1;
}

function isWriteTool(toolName) {
  return isEditWriteTool(toolName) || isCommandTool(toolName);
}

const TOOL_MATCHER = EDIT_WRITE_TOOL_NAMES.concat(COMMAND_TOOL_NAMES).join("|");

// collectEditWritePaths(toolInput) -> string[]
// Every target an edit-write call names, in all three key spellings and at both
// levels. Moved here from hooks/block-off-clearance-write/dispatch.js (#1780
// M-1/N-7 solved it there first) so enforce-worktree consumes the same
// implementation instead of a second, subtly different one.
//
// Non-string values are dropped rather than coerced: a caller asking "which
// paths did this call name?" must not be handed the string "undefined".
function collectEditWritePaths(toolInput) {
  const input = toolInput && typeof toolInput === "object" ? toolInput : {};
  const paths = [];
  const push = (obj) => {
    if (!obj || typeof obj !== "object") return;
    if (typeof obj.file_path === "string") paths.push(obj.file_path);
    if (typeof obj.path === "string") paths.push(obj.path);
    if (typeof obj.notebook_path === "string") paths.push(obj.notebook_path);
  };
  push(input);
  if (Array.isArray(input.edits)) for (const edit of input.edits) push(edit);
  return paths;
}

module.exports = {
  EDIT_WRITE_TOOL_NAMES,
  COMMAND_TOOL_NAMES,
  TOOL_MATCHER,
  isEditWriteTool,
  isCommandTool,
  isWriteTool,
  collectEditWritePaths,
  commandTextOf,
  commandListOf,
};
