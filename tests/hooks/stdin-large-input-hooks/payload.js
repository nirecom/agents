"use strict";
// Builds one hook-input JSON payload whose decisive field lands AFTER `size`
// bytes, so a reader that corrupts or truncates input past the first chunk
// cannot reach it. Usage: node payload.js <kind> <size> <outFile> [arg]
//   kind: dotenv | outbound | sysops | bashguard | mark | stop | gate | worktree
//   arg : file path (outbound / gate / worktree) or session id (mark / stop)
// size 0 writes an empty file (the zero-byte json-invalid case).
const fs = require("fs");

const [kind, sizeArg, outFile, arg] = process.argv.slice(2);
const size = Number(sizeArg);
if (!kind || !Number.isInteger(size) || size < 0 || !outFile) {
  process.stderr.write("usage: payload.js <kind> <size> <outFile> [arg]\n");
  process.exit(2);
}
if (size === 0) {
  fs.writeFileSync(outFile, "");
  process.exit(0);
}

const pad = "p".repeat(size);
const SENTINEL_TERM = "__cli_test_sentinel__";
const VERIFIED = 'echo "<<WORKFLOW_USER_VERIFIED: the change was verified in the running app>>"';

// The padding key is serialized first, so every decisive field follows it.
const builders = {
  dotenv: () => ({ padding: pad, tool_name: "Bash", tool_input: { command: "cat .env" } }),
  outbound: () => ({
    padding: pad,
    tool_name: "Write",
    // Content itself is padded too: the term sits past `size` bytes inside the
    // text scan-offensive receives, not only inside the hook's JSON.
    tool_input: { file_path: arg, content: pad + " " + SENTINEL_TERM + " end\n" },
  }),
  sysops: () => ({ padding: pad, tool_name: "Bash", tool_input: { command: "winget install jq" } }),
  bashguard: () => ({ padding: pad, tool_name: "Bash", tool_input: { command: "echo a && echo b" } }),
  mark: () => ({
    padding: pad,
    session_id: arg,
    tool_name: "Bash",
    tool_input: { command: VERIFIED },
    tool_response: { exit_code: 0, stdout: "", stderr: "" },
  }),
  stop: () => ({ padding: pad, session_id: arg, hook_event_name: "Stop", stop_hook_active: false }),
  gate: () => ({ padding: pad, tool_name: "Read", tool_input: { file_path: arg, filler: pad } }),
  worktree: () => ({
    padding: pad,
    tool_name: "Write",
    tool_input: { file_path: arg, content: pad + "\n" },
  }),
};

if (!builders[kind]) {
  process.stderr.write(`payload.js: unknown kind ${kind}\n`);
  process.exit(2);
}
fs.writeFileSync(outFile, JSON.stringify(builders[kind]()));
