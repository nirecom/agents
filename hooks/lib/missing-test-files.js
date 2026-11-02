"use strict";
// hooks/lib/missing-test-files.js — UNRUNNABLE lines caused by a missing test file (#2646).
// A missing file is a broken test path, not a missing runtime, so the accept handler refuses it.
// run-all prints one column-0 `UNRUNNABLE: <path> (missing: test file)` line per file (a child's
// copy arrives neutralized); the worker carries the count as a leading `Missing test files: N; `
// summary token, which the two runtime regexes below skip. One spec for the token, here only.

const TOKEN_PREFIX = "Missing test files: ";
const TOKEN_DIGITS = "\\d{1,9}";
const TOKEN_MAX = 999999999;
const MISSING_FILE_LINE_RE = /^UNRUNNABLE: .+ \(missing: test file\)[ \t]*$/;
const TOKEN_READ_RE = new RegExp(`^${TOKEN_PREFIX}(${TOKEN_DIGITS}); `);
// The digits are loose here so an unreadable token never hides the runtimes; readSummaryToken judges it.
const TOKEN_SKIP_SRC = `${TOKEN_PREFIX}[^;'\\r\\n]*; `;

const WORKER_MISSING_RE = new RegExp(`^summary:[ \\t]*'?(?:${TOKEN_SKIP_SRC})?Missing runtimes: ([^;'\\r\\n]+)`, "m");
const SUMMARY_MISSING_RE = new RegExp(`^(?:${TOKEN_SKIP_SRC})?Missing runtimes: ([^;\\r\\n]+)`);

function countMissingFileLines(lines) {
  if (!Array.isArray(lines)) return 0;
  return lines.filter((l) => MISSING_FILE_LINE_RE.test(String(l))).length;
}

function summaryToken(n) {
  if (!Number.isInteger(n) || n <= 0) return null;
  return `${TOKEN_PREFIX}${Math.min(n, TOKEN_MAX)}; `;
}

function withSummaryToken(summary, n) {
  const token = summaryToken(n);
  return token === null ? summary : `${token}${summary}`;
}

// An unreadable token (overflow, non-digits) counts as 1, so it can never read as "no missing file".
function readSummaryToken(summary) {
  const s = typeof summary === "string" ? summary : "";
  if (!s.startsWith(TOKEN_PREFIX)) return 0;
  const m = TOKEN_READ_RE.exec(s);
  const n = m === null ? NaN : Number(m[1]);
  return Number.isSafeInteger(n) ? n : 1;
}

module.exports = {
  countMissingFileLines,
  summaryToken,
  withSummaryToken,
  readSummaryToken,
  WORKER_MISSING_RE,
  SUMMARY_MISSING_RE,
};
