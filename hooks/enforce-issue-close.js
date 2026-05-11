#!/usr/bin/env node
// Claude Code PreToolUse hook: block raw `gh issue close` invocations through
// the Bash tool. Forces routing via the /issue-close skill, which sets
// ISSUE_CLOSE_SKILL=1 to bypass this guard.
//
// Scope: Claude Code Bash tool only. Web UI, mobile, gh from another shell —
// all bypass this hook. Use /issue-reconcile to recover from those.

const fs = require("fs");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (e) {
    // EOF or no stdin attached
  }
  return Buffer.concat(chunks).toString("utf8");
}

const input = readStdin();
if (!input || !input.trim()) {
  // No input — nothing to evaluate. Approve.
  process.exit(0);
}

let parsed;
try {
  parsed = JSON.parse(input);
} catch (e) {
  // Non-JSON / malformed — fail-open. The other PreToolUse hooks will catch
  // legitimately malformed payloads; we don't want to escalate here.
  process.exit(0);
}

if (!parsed || parsed.tool_name !== "Bash") {
  process.exit(0);
}

const cmd = (parsed.tool_input && parsed.tool_input.command) || "";

// Match `gh issue close` at start-of-command or after a shell separator
// (whitespace, `;`, `|`, `&`). The `\s+` between `gh`, `issue`, `close`
// tolerates multiple spaces; `\b` anchors the end of `close`.
const CLOSE_RE = /(?:^|[\s;|&])gh\s+issue\s+close\b/;

if (!CLOSE_RE.test(cmd)) {
  process.exit(0);
}

// Skill bypass.
if (process.env.ISSUE_CLOSE_SKILL === "1") {
  process.exit(0);
}

process.stderr.write(
  "`gh issue close` を直接実行することはできません。/issue-close を使用してください。\n" +
  "（skills/issue-close で transaction-safe な close + history.md 追記 + todo.md 更新を行います）\n"
);
process.exit(2);
