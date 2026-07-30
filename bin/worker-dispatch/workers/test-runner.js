"use strict";
// bin/worker-dispatch/workers/test-runner.js
//
// Stage 1 canary: the first of the six workers to move from an LLM subagent to a
// plain script. Chosen because it is the only one whose correct behaviour
// involves NO writes at all — its registry entry declares an empty writeScopes
// set, so fsguard.js refuses any write it might attempt. That makes "the
// dispatcher caused no side effects" a checkable property of the canary rather
// than a claim, which is what a canary is for.
//
// Output shape is agents/test-runner.md's `## Output contract`, rendered by
// emit.js (this module never touches stdout).

const { run: spawnRun, scriptExists } = require("../spawn");

const FAIL_LINE_RE = /^FAIL:\s+(.+?)\s+\(exit\s+-?\d+\)\s*$/;
const RESULTS_LINE_RE = /^Results:\s*(.+?)\s*$/;
const MAX_FAILING = 10;
const TAIL_LINES = 40;

function splitLines(text) {
  return String(text || "")
    .replace(/\r\n/g, "\n")
    .split("\n");
}

function parseFailingTests(lines) {
  const out = [];
  for (const line of lines) {
    const m = FAIL_LINE_RE.exec(line);
    if (m !== null) out.push(m[1]);
    if (out.length >= MAX_FAILING) break;
  }
  return out;
}

function parseResults(lines) {
  let found = null;
  for (const line of lines) {
    const m = RESULTS_LINE_RE.exec(line);
    if (m !== null) found = m[1].replace(/\s+/g, " ");
  }
  return found;
}

function run(payload, ctx) {
  const { anchors, entry } = ctx;
  const started = Date.now();
  const elapsed = () => Math.max(0, Math.round((Date.now() - started) / 1000));

  const script = scriptExists(entry, "runAll", anchors, payload.cwd);
  if (script === null) {
    return {
      status: "runner-error",
      exitCode: -1,
      durationSeconds: elapsed(),
      summary: "tests/run-all.sh was not found under the target worktree",
      failingTests: [],
      logTail: [],
    };
  }

  let res = null;
  try {
    res = spawnRun(entry, {
      anchors,
      command: "bash",
      script: "runAll",
      args: payload.test_args || [],
      cwd: payload.cwd,
      timeoutMs: (payload.timeout_seconds || 120) * 1000,
    });
  } catch (e) {
    return {
      status: "runner-error",
      exitCode: -1,
      durationSeconds: elapsed(),
      summary: `could not start the test suite: ${e && e.message ? e.message : "unknown error"}`,
      failingTests: [],
      logTail: [],
    };
  }

  const duration = elapsed();
  const lines = splitLines(res.stdout).concat(splitLines(res.stderr));
  const nonEmpty = lines.filter((l) => l.trim() !== "");
  const logTail = nonEmpty.slice(-TAIL_LINES);
  const failingTests = parseFailingTests(nonEmpty);
  const results = parseResults(nonEmpty);

  if (res.timedOut) {
    return {
      status: "timeout",
      exitCode: -1,
      durationSeconds: duration,
      summary: `the suite exceeded its ${payload.timeout_seconds || 120}s budget`,
      failingTests,
      logTail,
    };
  }
  if (res.spawnError !== null) {
    return {
      status: "runner-error",
      exitCode: -1,
      durationSeconds: duration,
      summary: `bash could not run the suite: ${res.spawnError}`,
      failingTests: [],
      logTail,
    };
  }

  const exitCode = typeof res.status === "number" ? res.status : -1;
  const status = exitCode === 0 ? "pass" : "fail";
  let summary = results !== null ? results : `exit_code=${exitCode}; ${nonEmpty.length} output lines`;

  // Never report an empty failing list for a failing suite without saying why —
  // a silent [] reads as "nothing failed", which is the opposite of the truth.
  if (status === "fail" && failingTests.length === 0) {
    summary = `${summary}; parse-degraded (no 'FAIL: <script> (exit N)' lines matched)`;
  }

  return {
    status,
    exitCode,
    durationSeconds: duration,
    summary,
    failingTests: status === "pass" ? [] : failingTests,
    logTail,
  };
}

module.exports = { run, parseFailingTests, parseResults };
