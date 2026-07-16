#!/usr/bin/env node
"use strict";

// Claude Code PostToolUse hook: detect a `git worktree add` branch conflict.
//
// Single responsibility: scan Bash tool stderr for exactly one pattern —
//   `fatal: '<branch>' is already used by worktree`
// — and, on a match, emit ONE non-blocking additionalContext guidance message.
// Never blocks (no `decision: "block"`), never uses `systemMessage`. Fail-open:
// any non-match, success exit, missing stderr, malformed input, or exception
// results in a silent noop (empty stdout, exit 0).

const fs = require("fs");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

// Exactly one pattern. Group 1 = the conflicting branch name (non-quote chars only,
// so the capture stops at the closing quote instead of spanning the trailing text).
const WORKTREE_CONFLICT_RE = /fatal: '([^']+)' is already used by worktree/;
// Optional trailing `at '<path>'` — surfaced to help locate the other worktree.
const WORKTREE_PATH_RE = /is already used by worktree at '([^']+)'/;

// Terminal-style tool names that carry the same `git worktree add` stderr shape as
// the Bash tool. Kept in sync with the settings.json PostToolUse matcher (CPR-5).
const TERMINAL_TOOL_NAMES = new Set(["Bash", "runInTerminal", "runCommands"]);

function main() {
  try {
    const input = JSON.parse(readStdin());
    if (!input || !TERMINAL_TOOL_NAMES.has(input.tool_name)) noopExit();

    const toolResponse = input.tool_response || {};
    const exitCode =
      toolResponse.exit_code ??
      toolResponse.exitCode ??
      (toolResponse.success === false ? 1 : 0);
    if (exitCode === 0) noopExit();

    const stderr = toolResponse.stderr;
    if (typeof stderr !== "string") noopExit();

    const m = stderr.match(WORKTREE_CONFLICT_RE);
    if (!m) noopExit();

    const branch = m[1];
    const pathMatch = stderr.match(WORKTREE_PATH_RE);
    const at = pathMatch ? ` (at '${pathMatch[1]}')` : "";
    const additionalContext =
      `Branch '${branch}' is already checked out in another worktree${at}. ` +
      "Run `git worktree list` to locate it, then use /worktree-end to complete " +
      "or /sweep-worktrees to reclaim it before continuing.";
    process.stdout.write(JSON.stringify({ additionalContext }));
    process.exit(0);
  } catch (_) {
    noopExit();
  }
}

if (require.main === module) main();

module.exports = { WORKTREE_CONFLICT_RE };
