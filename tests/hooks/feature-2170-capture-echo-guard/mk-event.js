"use strict";
// Build a PreToolUse event JSON on stdout so bash never has to hand-escape JSON.
//   node mk-event.js <tool_name> <arg...>
// runCommands -> tool_input.commands = [args...]; every other tool -> .command = args[0].
// "<NL>" in any arg is decoded to a real newline.

const args = process.argv.slice(2);
const tool = args[0] || "Bash";
const rest = args.slice(1).map((a) => a.split("<NL>").join("\n"));
const toolInput = tool === "runCommands" ? { commands: rest } : { command: rest[0] === undefined ? "" : rest[0] };
process.stdout.write(JSON.stringify({
  session_id: "test-2170",
  hook_event_name: "PreToolUse",
  tool_name: tool,
  tool_input: toolInput,
}));
