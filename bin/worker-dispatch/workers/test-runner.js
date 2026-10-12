"use strict";
// bin/worker-dispatch/workers/test-runner.js
//
// Stage 1 canary: the first worker moved from an LLM subagent to a plain script,
// chosen because it writes nothing at all. Its only declared scope is the
// control-outcome file, which fsguard.js admits for the dispatcher's own outcome
// record and never for this worker's writeCtx (#2544), so "the worker caused no
// side effects" stays a checkable property rather than a claim.
//
// Output shape is agents/test-runner.md's `## Output contract`, rendered by
// emit.js (this module never touches stdout).

const { run: spawnRun, scriptExists } = require("../spawn");

// Separators are ASCII blanks only: each one is in run-all-report.sh _RAR_REPORT_RE's set, so a line
// matched here is one the runner's neutralizer prefixes when a child prints it.
const FAIL_LINE_RE = /^FAIL:[ \t]+(.+?)[ \t]+\(exit[ \t]+-?\d+\)[ \t]*$/;
const RESULTS_LINE_RE = /^Results:[ \t]*(.+?)[ \t]*$/;
// The hook's own parser (hooks/lib/run-contract.js): this worker lifts the line OUT of the
// output so the renderer can put exactly one copy where the hook will look, and
// the two would silently disagree if they recognised different strings.
const { CONTRACT_PREFIX_RE, findSingleContract } = require("../../../hooks/lib/run-contract");
// run-all's whole-run exit for "nothing executed" (all SKIP, nothing selected, nothing launched).
const EXIT_NOTHING_EXECUTED = 77;
// Passing case lines would push the failing unit's context out of the tail window.
// `.*` as in _RAR_REPORT_RE: a path may hold blanks, and a child's own line of this shape is prefixed.
const PASSING_CASE_LINE_RE = /^(PASS|SKIP|XFAIL) .*::/;
// Line-anchored: a nested suite's copy arrives neutralized (prefixed), never at column 0.
const MISSING_RUNTIMES_LINE_RE = /^Missing runtimes: /;
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
 * @returns {{shape, pass, fail, skip, executed, unrunnable, timeout}|null} legacy: unrunnable/timeout null
 */
function parseRunContract(lines) {
  const c = findSingleContract((Array.isArray(lines) ? lines : []).map(String));
  return c.reason === undefined ? c : null;
}

// Top to bottom: a current contract with UNRUNNABLE>0 on a clean or nothing-executed exit,
// then exit 77 (nothing executed is no failure), then exit 0; anything else fails.
function statusOf(exitCode, contract) {
  const clean = exitCode === 0 || exitCode === EXIT_NOTHING_EXECUTED;
  if (clean && contract !== null && contract.shape === "current" && contract.unrunnable > 0) return "unrunnable";
  if (exitCode === EXIT_NOTHING_EXECUTED) return "skip";
  return exitCode === 0 ? "pass" : "fail";
}

function lastMissingRuntimesLine(lines) {
  let found = null;
  for (const line of lines) if (MISSING_RUNTIMES_LINE_RE.test(line)) found = line.trim();
  return found;
}

// Contract lines are removed from the log source in ALL cases, including the
// ambiguous two-line one: leaving a forged copy inside log_tail would launder it
// into the transcript as fact. Removal is exactly one line per match, so the
// failing test's own output — which sits directly above it — is untouched.
function stripContractLines(lines) {
  return lines.filter((l) => !CONTRACT_PREFIX_RE.test(String(l)));
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

  // Deadline lets the suite exit cleanly before the worker's own timeout (#1832).
  // Lead args are derived/validated ints — never caller argv text.
  const deadline = Math.max(30, (payload.timeout_seconds || 120) - 5);
  const lead = ["--deadline", String(deadline)];
  if (typeof payload.jobs === "number") lead.push("-j", String(payload.jobs));

  let res = null;
  try {
    res = spawnRun(entry, {
      anchors,
      command: "bash",
      script: "runAll",
      args: lead.concat(payload.test_args || []),
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
  const logTail = stripContractLines(nonEmpty)
    .filter((l) => !PASSING_CASE_LINE_RE.test(l))
    .slice(-TAIL_LINES);
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
  // A clean exit with unlaunched files is not a pass: the runtime the user must install
  // is named in the summary, so the reader sees the remedy without opening log_tail.
  const status = statusOf(exitCode, runContract);
  let summary = results !== null ? results : `exit_code=${exitCode}; ${nonEmpty.length} output lines`;
  const missing = lastMissingRuntimesLine(nonEmpty);
  // First, because the renderer cuts a long summary at its end and the runtimes are the remedy.
  if (missing !== null) summary = `${missing}; ${summary}`;

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
