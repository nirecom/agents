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

const { isStrictSentinel } = require("../../hooks/lib/sentinel-patterns");

const SENTINEL_SCAN_RE = /<<\s*WORKFLOW/i;
const SENTINEL_REDACT_RE = /<<\s*WORKFLOW/gi;

const MAX_LINE = 500;
const MAX_SUMMARY = 300;
const MAX_YAML_SUMMARY = 296; // + the two single quotes stays inside 300
const MAX_TAIL_LINES = 40;
const MAX_FAILING_TESTS = 10;

const TAB_CODE = 9;
const SPACE_CODE = 32;
const DEL_CODE = 127;

const FALLBACK_MSG = "output withheld (sentinel-like content detected)";
const FALLBACK_TRIPLE = `status: failed\nsummary: ${FALLBACK_MSG}\nartifact_path: (none)\n`;
const FALLBACK_TRIPLE_QUOTED = `status: failed\nsummary: "${FALLBACK_MSG}"\nartifact_path: "(none)"\n`;
// `runner-error`, not `failed`: the YAML renderer's status vocabulary is
// pass | fail | timeout | runner-error, and /run-tests RNT-9 branches on it.
const FALLBACK_YAML =
  "status: runner-error\nexit_code: -1\nduration_seconds: 0\n" +
  `summary: '${FALLBACK_MSG}'\nfailing_tests: []\nlog_tail: |\n  ${FALLBACK_MSG}\n`;

// Every C0 control (including CR/LF) and DEL becomes a space; TAB survives.
// Written as a code-point walk rather than a regex escape class so the source
// carries no literal control bytes of its own.
function collapseControl(input) {
  let out = "";
  for (const ch of input) {
    const code = ch.codePointAt(0);
    out += (code < SPACE_CODE && code !== TAB_CODE) || code === DEL_CODE ? " " : ch;
  }
  return out;
}

// The redaction step on its own, for the other boundary at which untrusted bytes
// re-enter a Claude Code transcript: an artifact file the calling skill reads.
// Same substitution as sanitizeLine's, so stdout and artifacts cannot drift.
function redactSentinels(input) {
  return String(input === null || input === undefined ? "" : input).replace(
    SENTINEL_REDACT_RE,
    "<<_REDACTED_WORKFLOW",
  );
}

function sanitizeLine(input, maxLen) {
  let out = input === null || input === undefined ? "" : String(input);
  out = collapseControl(out);
  out = out.replace(SENTINEL_REDACT_RE, "<<_REDACTED_WORKFLOW");
  const limit = typeof maxLen === "number" && maxLen > 0 ? maxLen : MAX_LINE;
  if (out.length > limit) out = `${out.slice(0, limit - 3)}...`;
  return out;
}

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

function renderTestRunnerYaml(result) {
  const lines = [];
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
  const tailSource = Array.isArray(result.logTail) ? result.logTail : [];
  const tail = tailSource
    .map((l) => sanitizeLine(l, MAX_LINE))
    .filter((l) => l.trim() !== "")
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
  redactSentinels,
  sanitizeLine,
  render,
  renderStatusTriple,
  renderTestRunnerYaml,
  write,
  failure,
  isTainted,
};
