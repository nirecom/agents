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
const GIT_NON_EXEC_RE = /^git\s+(?:-C\s+(?:"[^"]+"|'[^']+'|\S+)\s+)?(diff|log|show|status|blame|ls-files|ls-tree|cat-file|rev-parse|fetch|remote|add|commit|push|merge|rebase|pull|stash|tag)\b/;

// Test runner / test path patterns.
const TEST_PATH_RE = /\btests?\//;
const TEST_RUNNER_RE = /\b(pytest|jest|vitest|mocha|pester|invoke-pester)\b/i;
const TEST_RUNNER_UV_RE = /\buv\s+run\s+pytest\b/;
const TEST_BASH_RE = /\b(bash|sh|node|pwsh|powershell(?:\.[a-z]+)?)\s+\S*tests?\//i;
const PESTER_RE = /\.Tests\.ps1\b/i;

// Split a command into segments at top-level (unquoted) occurrences of
// && || | ; and newline. Operators inside single or double quotes do NOT
// split, so `echo "a && b"` stays a single segment. Pure string scan,
// never throws — fail-open friendly. Backslash escapes the next char.
function splitTopLevelSegments(command) {
  const segments = [];
  let current = "";
  let quote = null; // null | '\'' | '"'
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      // Inside quotes: only a matching close-quote (or backslash escape) is special.
      if (ch === "\\" && i + 1 < command.length) {
        current += ch + command[i + 1];
        i++;
        continue;
      }
      if (ch === quote) quote = null;
      current += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === "\\" && i + 1 < command.length) {
      current += ch + command[i + 1];
      i++;
      continue;
    }
    // Top-level operators: && || (two chars) and | ; \n (one char).
    if ((ch === "&" && command[i + 1] === "&") || (ch === "|" && command[i + 1] === "|")) {
      segments.push(current);
      current = "";
      i++; // consume the second operator char
      continue;
    }
    if (ch === "|" || ch === ";" || ch === "\n") {
      segments.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  segments.push(current);
  return segments;
}

// True iff a single command segment matches a test-detection pattern.
function segmentMatchesDetection(seg) {
  return (
    TEST_PATH_RE.test(seg) ||
    TEST_RUNNER_RE.test(seg) ||
    TEST_RUNNER_UV_RE.test(seg) ||
    TEST_BASH_RE.test(seg) ||
    PESTER_RE.test(seg)
  );
}

// True iff a single segment is excluded (sentinel echo / read-only / git non-exec).
function segmentExcluded(seg) {
  if (seg.startsWith('echo "<<') || seg.startsWith("echo '<<")) return true;
  if (READ_ONLY_RE.test(seg)) return true;
  if (GIT_NON_EXEC_RE.test(seg)) return true;
  return false;
}

function isTestCommand(command) {
  const trimmed = command.trim();
  // Quote-aware split on top-level shell operators (&&, ||, |, ;, newline).
  // Operators inside quotes are NOT split points, so `echo "a && pytest tests/"`
  // stays one segment and is excluded by the leading `echo` (read-only).
  const segments = splitTopLevelSegments(trimmed);
  for (const raw of segments) {
    const seg = raw.trim();
    if (!seg) continue;
    if (segmentExcluded(seg)) continue;
    if (segmentMatchesDetection(seg)) return true;
  }
  return false;
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
