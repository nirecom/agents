#!/usr/bin/env node
// Claude Code PermissionRequest hook: auto-allow specific Bash commands
// Reads allowed commands from .context-private/allowed-commands.txt
// Fail-safe: file missing or error → no output (falls through to ask dialog)

const fs = require("fs");
const path = require("path");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function allow() {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }));
}

// Normalize: trim, collapse whitespace, strip CRLF
function normalize(s) {
  return s.replace(/\r\n/g, "\n").trim().replace(/\s+/g, " ");
}

try {
  const input = JSON.parse(readStdin());
  if (input.tool_name !== "Bash") process.exit(0);

  const command = (input.tool_input || {}).command || "";
  if (!command) process.exit(0);

  const allowFile = process.env.ALLOWED_COMMANDS_FILE ||
    path.join(path.resolve(__dirname, "..", ".."), ".context-private", "allowed-commands.txt");

  if (!fs.existsSync(allowFile)) process.exit(0);

  const lines = fs.readFileSync(allowFile, "utf8").split(/\r?\n/);
  const allowed = new Set(
    lines.filter(l => { const t = l.trim(); return t && !t.startsWith("#"); })
         .map(l => normalize(l))
  );

  if (allowed.has(normalize(command))) {
    allow();
  }
} catch (e) {
  // Fail-safe: any error → silent exit (ask dialog)
}
