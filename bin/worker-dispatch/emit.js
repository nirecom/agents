"use strict";
// bin/worker-dispatch/emit.js
//
// THE ONLY MODULE IN THIS DISPATCHER THAT WRITES TO STDOUT.
// tests/feature-1643-worker-dispatch-sentinel-stdout.sh asserts that by source
// scan. Keep it that way: a single boundary is what makes sentinel
// neutralization a property of the program rather than a habit.
//
// Why this matters. Worker stdout is read back into a Claude Code transcript.
// A `<<WORKFLOW_...>>` sequence appearing there would be indistinguishable from
// a real workflow sentinel emitted by the session itself — child test output
// could mark a workflow step complete. So:
//
//   1. Per line: control chars and newlines collapse to spaces, `<< WORKFLOW`
//      becomes `<<_REDACTED_WORKFLOW`, then the line is length-capped.
//   2. Per line: hooks/lib/sentinel-patterns.isStrictSentinel() — the same
//      predicate the hooks use, so the two can never drift apart.
//   3. Whole rendered string, after assembly: re-scanned against /<<\s*WORKFLOW/i.
//      `\s` spans newlines, so a sentinel split across two log_tail lines is
//      caught here even though neither line matched on its own.
//
// Step 3 is not redundancy — steps 1 and 2 look at fragments, step 3 looks at
// what a reader actually sees. On a step-3 hit the rendered output is DISCARDED
// and replaced by a fixed literal that contains no untrusted bytes at all.

// collapseControl / redactSentinels / sanitizeLine live in hooks/lib/
// output-sanitize.js: hooks/workflow-run-tests.js needs the SAME substitution for
// the trigger_command annotation it records, and two copies of a security
// substitution are two things to keep in step (CPR-SSOT). They are re-exported
// below as ordinary properties, so this module's public surface is unchanged.
const { isStrictSentinel } = require("../../hooks/lib/sentinel-patterns");
const {
  collapseControl,
  redactSentinels,
  sanitizeLine,
  MAX_LINE,
} = require("../../hooks/lib/output-sanitize");

const SENTINEL_SCAN_RE = /<<\s*WORKFLOW/i;

const MAX_SUMMARY = 300;
const MAX_YAML_SUMMARY = 296; // + the two single quotes stays inside 300
const MAX_TAIL_LINES = 40;
const MAX_FAILING_TESTS = 10;

const FALLBACK_MSG = "output withheld (sentinel-like content detected)";
const FALLBACK_TRIPLE = `status: failed\nsummary: ${FALLBACK_MSG}\nartifact_path: (none)\n`;
const FALLBACK_TRIPLE_QUOTED = `status: failed\nsummary: "${FALLBACK_MSG}"\nartifact_path: "(none)"\n`;
// `runner-error`, not `failed`: the YAML renderer's status vocabulary is
// pass | fail | timeout | runner-error, and /run-tests RNT-9 branches on it.
const FALLBACK_YAML =
  "status: runner-error\nexit_code: -1\nduration_seconds: 0\n" +
  `summary: '${FALLBACK_MSG}'\nfailing_tests: []\nlog_tail: |\n  ${FALLBACK_MSG}\n`;

// Value for an UNQUOTED contract slot: no double quotes at all, never empty.
function plainValue(input, maxLen, fallback) {
  const out = sanitizeLine(input, maxLen).replace(/"/g, "'").trim();
  return out === "" ? fallback : out;
}

// Value for a QUOTED contract slot.
function quotedValue(input, maxLen, fallback) {
  return `"${plainValue(input, maxLen, fallback)}"`;
}

function yamlSingleQuoted(input, maxLen, fallback) {
  const out = sanitizeLine(input, maxLen).trim();
  const body = out === "" ? fallback : out;
  return `'${body.replace(/'/g, "''")}'`;
}

function toInt(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : fallback;
}

// --- renderers -------------------------------------------------------------

function renderStatusTriple(result, quoted) {
  const status = plainValue(result.status, 64, "failed");
  const summary = quoted
    ? quotedValue(result.summary, MAX_SUMMARY, "no summary")
    : plainValue(result.summary, MAX_SUMMARY, "no summary");
  const artifact = quoted
    ? quotedValue(result.artifactPath, MAX_LINE, "(none)")
    : plainValue(result.artifactPath, MAX_LINE, "(none)");
  return `status: ${status}\nsummary: ${summary}\nartifact_path: ${artifact}\n`;
}

// The worker reports the suite's contract as structured data; this renders it
// back as ONE line, unindented, at the very top — the only place the run_tests
// hook can read it without parsing the `log_tail` block scalar (#1378).
// Both spellings the worker may hand over are accepted (object today, plain
// string historically); anything else yields no line at all, because a contract
// this renderer invented would be a verdict the suite never gave.
function formatRunContract(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") {
    const m = /^\s*(?:RUN_CONTRACT:\s*)?PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)\s*$/.exec(value);
    return m === null ? null : `PASS=${m[1]} FAIL=${m[2]} SKIP=${m[3]} EXECUTED=${m[4]}`;
  }
  if (typeof value !== "object") return null;
  const nums = ["pass", "fail", "skip", "executed"].map((k) => value[k]);
  if (nums.some((n) => typeof n !== "number" || !Number.isFinite(n) || n < 0)) return null;
  const [p, f, s, e] = nums.map((n) => Math.trunc(n));
  return `PASS=${p} FAIL=${f} SKIP=${s} EXECUTED=${e}`;
}

// Same shape the hook's parser recognises, so "would the parser see two of
// these?" is answered with the parser's own question.
const CONTRACT_LINE_RE = /^[ \t]*RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+/;
const CONTRACT_CAPTURE_RE =
  /^[ \t]*RUN_CONTRACT: (PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+)[ \t]*$/;

// RETIRED, DEFINITION ONLY — deliberately not called (#1273 round 3 / NEW-L1).
//
// It used to lift a contract-shaped line out of the log tail into the
// authoritative top-level slot when the worker handed over no structured
// contract. What it actually was, by then, is a launderer: it copied untrusted
// log text into the ONE position the hook treats as a verdict, with no check on
// where that text came from. And it had no live purpose — workers/test-runner.js
// parses the suite's contract into `runContract` AND strips contract lines out of
// `logTail` before handing the result over, so the fallback was unreachable for
// every worker in the dispatcher.
//
// The top-level slot is now written from structured worker data alone. Kept here
// unwired, rather than deleted, so a future caller must add the source-identity
// check that this shape never had; a caller that simply re-wires it reopens the
// hole.
//
// Exactly-one, mirroring the hook's own rule: zero is nothing to lift, and two
// is ambiguous — inventing a winner would be this renderer issuing a verdict the
// suite never gave.
// eslint-disable-next-line no-unused-vars
function promoteContractFromTail(tailSource) {
  const found = [];
  for (const l of tailSource) {
    const m = CONTRACT_CAPTURE_RE.exec(sanitizeLine(l, MAX_LINE));
    if (m !== null) found.push(m[1]);
  }
  return found.length === 1 ? found[0] : null;
}

function renderTestRunnerYaml(result) {
  const lines = [];
  const tailSource = Array.isArray(result.logTail) ? result.logTail : [];
  // Emitted BEFORE `status:` so the contract is the first line of the payload.
  // Structured worker data is its ONLY source: see the retired promotion helper
  // above for why log-tail text may not reach this slot.
  const contract = formatRunContract(result.runContract);
  if (contract !== null) lines.push(`RUN_CONTRACT: ${contract}`);
  lines.push(`status: ${plainValue(result.status, 64, "runner-error")}`);
  lines.push(`exit_code: ${toInt(result.exitCode, -1)}`);
  lines.push(`duration_seconds: ${Math.max(0, toInt(result.durationSeconds, 0))}`);
  lines.push(`summary: ${yamlSingleQuoted(result.summary, MAX_YAML_SUMMARY, "no summary")}`);

  const failing = Array.isArray(result.failingTests)
    ? result.failingTests.slice(0, MAX_FAILING_TESTS)
    : [];
  if (failing.length === 0) {
    lines.push("failing_tests: []");
  } else {
    lines.push("failing_tests:");
    for (const name of failing) lines.push(`  - ${yamlSingleQuoted(name, MAX_LINE, "(unnamed)")}`);
  }

  lines.push("log_tail: |");
  // The log_tail copy is dropped ONLY when a top-level line was emitted. Two
  // visible contract lines trip the hook's exactly-one rule (ambiguous →
  // demotion, i.e. #1378 wearing a different face); dropping unconditionally
  // would instead delete the sole contract of a worker that reported none.
  const tail = tailSource
    .map((l) => sanitizeLine(l, MAX_LINE))
    .filter((l) => l.trim() !== "")
    .filter((l) => contract === null || !CONTRACT_LINE_RE.test(l))
    .slice(-MAX_TAIL_LINES);
  if (tail.length === 0) lines.push("  (no output)");
  else for (const l of tail) lines.push(`  ${l}`);

  // No closing fence: the block scalar must run to end-of-output, and any
  // non-indented trailing line would terminate `log_tail` mid-value.
  return `${lines.join("\n")}\n`;
}

// The shape a worker owes the caller when it has nothing usable to say. Kept
// separate from `failure()` so `render()` can fall back to it without writing.
function failureResult(entry, message) {
  const renderer = entry && entry.renderer ? entry.renderer : "status-triple";
  if (renderer === "test-runner-yaml") {
    return {
      status: "runner-error",
      exitCode: -1,
      durationSeconds: 0,
      summary: message,
      failingTests: [],
      logTail: [],
    };
  }
  return { status: "failed", summary: message, artifactPath: "(none)" };
}

// A worker that *returns* a degenerate value (rather than throwing) must not
// reach the renderers' unguarded `result.status` — that is an uncaught
// TypeError, exit 1, and a stack trace carrying absolute host paths, instead of
// the contracted status line at exit 0.
function coerce(entry, result) {
  if (result !== null && typeof result === "object") return result;
  const shape = result === undefined ? "undefined" : result === null ? "null" : typeof result;
  return failureResult(entry, `worker returned no usable result (${shape})`);
}

function render(entry, result) {
  const renderer = entry && entry.renderer ? entry.renderer : "status-triple";
  const value = coerce(entry, result);
  if (renderer === "test-runner-yaml") return renderTestRunnerYaml(value);
  return renderStatusTriple(value, renderer === "status-triple-quoted");
}

function fallbackFor(entry) {
  const renderer = entry && entry.renderer ? entry.renderer : "status-triple";
  if (renderer === "test-runner-yaml") return FALLBACK_YAML;
  if (renderer === "status-triple-quoted") return FALLBACK_TRIPLE_QUOTED;
  return FALLBACK_TRIPLE;
}

function isTainted(text) {
  if (SENTINEL_SCAN_RE.test(text)) return true;
  return text.split("\n").some((line) => isStrictSentinel(line.trim()));
}

function write(entry, result) {
  const rendered = render(entry, result);
  process.stdout.write(isTainted(rendered) ? fallbackFor(entry) : rendered);
}

// A validation / dispatch failure, rendered through the worker's own renderer so
// callers parse one shape whether the worker ran or never got the chance to.
function failure(entry, message) {
  write(entry, failureResult(entry, message));
}

module.exports = {
  // Re-exported from hooks/lib/output-sanitize.js as plain properties (never
  // getters): the sentinel-stdout test resolves them off this module.
  collapseControl,
  redactSentinels,
  sanitizeLine,
  render,
  renderStatusTriple,
  renderTestRunnerYaml,
  write,
  failure,
  isTainted,
};
