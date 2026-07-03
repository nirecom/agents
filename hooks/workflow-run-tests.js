#!/usr/bin/env node
// Claude Code PostToolUse hook: mark run_tests from the run-all.sh contract.
//
// Fires on every Bash tool call. Trust model (#1242, Approach C′): completion
// is driven ONLY by the machine-readable RUN_CONTRACT line that tests/run-all.sh
// emits — never inferred from a raw exit code. For a detected test command:
//   non-zero exit                          → run_tests: pending (fail-safe)
//   run-all.sh provenance + exactly one
//     valid RUN_CONTRACT (executed>0,
//     fail==0)                             → run_tests: complete (if write_tests satisfied)
//   any other test command / no contract   → run_tests: pending (active demotion)
//
// The run_tests sentinel (WORKFLOW_MARK_STEP_run_tests_complete) is the other
// completion authority. Sentinel echo commands and read-only commands are excluded.

const fs = require("fs");
const { resolveSessionId, markStep, readState } = require("./lib/workflow-state");

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

// True iff the command string invokes run-all.sh (the only authorised contract
// emitter). Provenance-only check — does not analyse pipe/compound structure.
// Matches: tests/run-all.sh, ./tests/run-all.sh, bash tests/run-all.sh, etc.
const RUN_ALL_SH_RE = /(?:^|[\s;|&])(?:[./\w-]*\/)?tests\/run-all\.sh\b/;
function isRunAllSh(command) {
  return RUN_ALL_SH_RE.test(command);
}

// Count and parse RUN_CONTRACT lines in tool_response.stdout.
// Returns null in all non-success cases:
//   - stdout absent or not a string
//   - zero well-formed contract lines (absent)
//   - two or more well-formed contract lines (ambiguous: forged append or fixture collision)
//   - any field is NaN (malformed integer in the single line)
// Contract format is fixed: PASS FAIL SKIP EXECUTED (in this order). Extension
// via #1241 requires lockstep changes to both run-all.sh and this parser.
function parseContract(toolResponse) {
  const stdout = (toolResponse && typeof toolResponse.stdout === "string")
    ? toolResponse.stdout : "";
  if (!stdout) return null;

  const CONTRACT_LINE_RE =
    /^RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)/gm;
  const matches = [...stdout.matchAll(CONTRACT_LINE_RE)];

  // Exactly-one rule: zero → absent, two or more → ambiguous. Both → null.
  if (matches.length !== 1) return null;

  const m = matches[0];
  const p = parseInt(m[1], 10);
  const f = parseInt(m[2], 10);
  const s = parseInt(m[3], 10);
  const e = parseInt(m[4], 10);
  if ([p, f, s, e].some((n) => isNaN(n))) return null;
  return { pass: p, fail: f, skip: s, executed: e };
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
  // Fast path: non-zero exit code always reverts to pending regardless of contract.
  if (exitCode !== 0) {
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: true,
      last_exit_code: exitCode,
    });
    done();
  }

  // C′ contract-trust model with provenance gating and exactly-one rule.
  // Trust conditions (all must hold):
  //   (a) provenance: command contains a run-all.sh invocation (isRunAllSh)
  //   (b) stdout has exactly one well-formed RUN_CONTRACT: line (parseContract)
  //       — zero → absent; >=2 → ambiguous (forged append or fixture collision)
  //   (c) validity: executed>0, (PASS+FAIL)>0, FAIL==0
  // Any failure → ACTIVE DEMOTION to pending (clears a stale complete).
  const hasProvenance = isRunAllSh(command);
  const contract = hasProvenance ? parseContract(toolResponse) : null;

  const contractValid = contract !== null
    && contract.executed > 0
    && (contract.pass + contract.fail) > 0  // all-SKIP guard
    && contract.fail === 0;

  if (!contractValid) {
    // ACTIVE DEMOTION: a test command ran but no trusted valid contract arrived.
    // Covers: ad-hoc commands, piped run-all.sh, no-match (executed=0),
    // all-skip, FAIL>0, compound-forge (>=2 contract lines), fixture collision.
    markStep(sessionId, "run_tests", "pending", {
      last_run_failed: false,
      contract_absent: !hasProvenance || contract === null,
    });
    done();
  }

  // Contract is valid. Preserve the PR #1165 write_tests guard: only mark
  // run_tests complete when write_tests is already complete or skipped.
  const state = readState(sessionId);
  const writeTestsStatus = state && state.steps && state.steps.write_tests
    ? state.steps.write_tests.status
    : undefined;
  if (writeTestsStatus === "complete" || writeTestsStatus === "skipped") {
    markStep(sessionId, "run_tests", "complete");
  }
  // else: write_tests not yet satisfied → fail-open (do not mark complete).
} catch (e) {
  // fail-open — gate will block on next commit if state was not written
}

done();
