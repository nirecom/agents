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
// Deliberately the SAME shape (and the same leading-whitespace tolerance) as
// hooks/workflow-run-tests.js's parser: this worker lifts the line OUT of the
// output so the renderer can put exactly one copy where the hook will look, and
// the two would silently disagree if they recognised different strings.
const CONTRACT_LINE_RE = /^[ \t]*RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)/;
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

/**
 * The suite's RUN_CONTRACT, lifted out of its raw output.
 *
 * The EXACTLY-ONE rule is applied here rather than deferred to the hook: zero
 * lines and two lines both mean "no trustworthy contract", and a worker that
 * emitted one anyway would be manufacturing a verdict the suite never gave.
 *
 * @param {string[]} lines
 * @returns {{pass: number, fail: number, skip: number, executed: number}|null}
 */
function parseRunContract(lines) {
  const matches = [];
  for (const line of Array.isArray(lines) ? lines : []) {
    const m = CONTRACT_LINE_RE.exec(String(line));
    if (m !== null) matches.push(m);
  }
  if (matches.length !== 1) return null;
  const [, p, f, s, e] = matches[0];
  const nums = [p, f, s, e].map((n) => parseInt(n, 10));
  if (nums.some((n) => !Number.isFinite(n))) return null;
  return { pass: nums[0], fail: nums[1], skip: nums[2], executed: nums[3] };
}

// Contract lines are removed from the log source in ALL cases, including the
// ambiguous two-line one: leaving a forged copy inside log_tail would launder it
// into the transcript as fact. Removal is exactly one line per match, so the
// failing test's own output — which sits directly above it — is untouched.
function stripContractLines(lines) {
  return lines.filter((l) => !CONTRACT_LINE_RE.test(String(l)));
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
      runContract: null,
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
      runContract: null,
    };
  }

  const duration = elapsed();
  const lines = splitLines(res.stdout).concat(splitLines(res.stderr));
  const nonEmpty = lines.filter((l) => l.trim() !== "");
  const runContract = parseRunContract(nonEmpty);
  const logTail = stripContractLines(nonEmpty).slice(-TAIL_LINES);
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
      runContract: null,
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
      runContract: null,
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
    runContract,
  };
}

module.exports = { run, parseFailingTests, parseResults, parseRunContract };
