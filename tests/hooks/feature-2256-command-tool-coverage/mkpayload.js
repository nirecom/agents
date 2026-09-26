#!/usr/bin/env node
"use strict";
// Hook stdin payload builder for the feature-2256-command-tool-coverage sections.
// Inputs come from env vars only, so no shell quoting ever reaches a JSON literal:
//   SHAPE  bash | runInTerminal | rc0 | rc1 | rcmix | edit | write
//   CMD    the command text (or, for edit/write, the file path)
//   LEAD   rc1/rcmix first element (default: an unrelated command)
//   PCWD / SID / EXITCODE  optional tool_input.cwd, session_id, tool_response

const shape = process.env.SHAPE;
const cmd = process.env.CMD || "";
const lead = process.env.LEAD || "git status --short";
const cwd = process.env.PCWD || "";
const sid = process.env.SID || "";
const exitCode = process.env.EXITCODE;

let toolName;
let toolInput;
if (shape === "bash") {
  toolName = "Bash";
  toolInput = { command: cmd };
} else if (shape === "runInTerminal") {
  toolName = "runInTerminal";
  toolInput = { command: cmd };
} else if (shape === "rc0") {
  toolName = "runCommands";
  toolInput = { commands: [cmd] };
} else if (shape === "rc1" || shape === "rcmix") {
  toolName = "runCommands";
  toolInput = { commands: shape === "rc1" ? [lead, cmd] : [cmd, lead] };
} else if (shape === "edit") {
  toolName = "Edit";
  toolInput = { file_path: cmd, old_string: "placeholder", new_string: lead };
} else if (shape === "write") {
  toolName = "Write";
  toolInput = { file_path: cmd, content: lead };
} else {
  process.stderr.write("mkpayload: unknown SHAPE " + String(shape) + "\n");
  process.exit(2);
}

if (cwd) toolInput.cwd = cwd;
const out = { tool_name: toolName, tool_input: toolInput, session_id: sid };
if (exitCode !== undefined && exitCode !== "") {
  out.tool_response = { exit_code: Number(exitCode) };
}
process.stdout.write(JSON.stringify(out));
