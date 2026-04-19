#!/usr/bin/env node
// Claude Code PostToolUse hook: auto-mark run_tests based on Bash exit code.
//
// Fires on every Bash tool call. Detects test-runner commands (commands that
// reference tests/ paths or known test runners) and updates run_tests state:
//   exit 0  → run_tests: complete
//   exit ≠ 0 → run_tests: pending  (last-run-wins — reverts to pending on failure)
//
// Sentinel echo commands and read-only commands are excluded.

const fs = require("fs");
const { resolveSessionId, markStep } = require("./lib/workflow-state");

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

function done() {
  console.log(JSON.stringify({}));
  process.exit(0);
}

// Read-only / non-execution command prefixes — exclude from test detection.
// Also excludes all git subcommands except those that could actually run tests.
const READ_ONLY_RE = /^(ls|cat|head|tail|grep|rg|find|wc|file|stat|echo|printf|which|type|pwd)\b/;
const GIT_NON_EXEC_RE = /^git\s+(diff|log|show|status|blame|ls-files|ls-tree|cat-file|rev-parse|fetch|remote|add|commit|push|merge|rebase|pull|stash|tag)\b/;

// Test runner / test path patterns.
const TEST_PATH_RE = /\btests?\//;
const TEST_RUNNER_RE = /\b(pytest|jest|vitest|mocha|pester|invoke-pester)\b/i;
const TEST_RUNNER_UV_RE = /\buv\s+run\s+pytest\b/;
const TEST_BASH_RE = /\b(bash|sh|node|pwsh|powershell(?:\.[a-z]+)?)\s+\S*tests?\//i;
const PESTER_RE = /\.Tests\.ps1\b/i;

function isTestCommand(command) {
  const trimmed = command.trim();

  // Sentinel echoes are not test runs.
  if (trimmed.startsWith('echo "<<') || trimmed.startsWith("echo '<<")) return false;

  // Extract the first token of the command (before any shell operators).
  const firstToken = trimmed.split(/[\s|&;]/)[0].toLowerCase();

  if (READ_ONLY_RE.test(trimmed)) return false;
  if (GIT_NON_EXEC_RE.test(trimmed)) return false;

  return (
    TEST_PATH_RE.test(trimmed) ||
    TEST_RUNNER_RE.test(trimmed) ||
    TEST_RUNNER_UV_RE.test(trimmed) ||
    TEST_BASH_RE.test(trimmed) ||
    PESTER_RE.test(trimmed)
  );
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

if (!input || input.tool_name !== "Bash") done();

const command = ((input.tool_input && input.tool_input.command) || "").trim();
if (!command) done();

if (!isTestCommand(command)) done();

const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);

const sessionId = input.session_id || resolveSessionId();
if (!sessionId) done();

try {
  if (exitCode === 0) {
    markStep(sessionId, "run_tests", "complete");
  } else {
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: true,
      last_exit_code: exitCode,
    });
  }
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
