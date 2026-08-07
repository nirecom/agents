// hooks/lib/write-tools.js
// SSOT (CPR-SSOT) for the WRITE-CAPABLE TOOL CLASSES that PreToolUse hooks guard,
// and the payload shapes each class uses to name its target.
//
//   edit-write class : Edit, Write, MultiEdit, editFiles, NotebookEdit —
//                      target(s) under file_path/path/notebook_path, at the
//                      top level or per-entry in an `edits[]` array
//   command class    : Bash, runInTerminal, runCommands (see
//                      hooks/lib/tool-command-text.js for its payload)
//
// Every guard needs both classes (CPR-ORTH) — enforce-worktree.js used to
// recognize only the original four tools, so editFiles/NotebookEdit/
// runInTerminal/runCommands bypassed main-worktree enforcement outright.
//
// TOOL_MATCHER is the settings.json `matcher` string; kept here so the
// registration and runtime branch cannot silently drift (settings.json is
// data, so tests/ assert the two stay in sync).
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
// Every target an edit-write call names, in all three key spellings and at
// both levels — moved here from dispatch.js so enforce-worktree consumes the
// same implementation instead of a second, subtly different one. Non-string
// values are dropped rather than coerced.
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
