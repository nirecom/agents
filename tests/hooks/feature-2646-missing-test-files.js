"use strict";
// Tests: hooks/lib/missing-test-files.js
// Tags: TL1, hooks, run-tests, unrunnable, missing-test-file, summary-token, regex, table-driven, in-process, scope:issue-specific
// #2646: an UNRUNNABLE line for a test file that no longer exists is a broken test path, not a
// missing runtime, so the accept handler must refuse it. This file pins the shared parser that
// counts those lines in run-all output, carries the count through the worker summary as the
// `Missing test files: N; ` token, and still reads the runtimes from summaries with and without it.
const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");

const assert = require("node:assert");
const path = require("node:path");

const MODULE = path.join(__dirname, "..", "..", "hooks", "lib", "missing-test-files.js");

// Loaded per test, so a missing module fails every case with the same plain reason.
function load() {
  try {
    return require(MODULE);
  } catch (e) {
    throw new Error(`hooks/lib/missing-test-files.js cannot be loaded: ${e.message}`);
  }
}

const GONE = "UNRUNNABLE: tests/gone.sh (missing: test file)";
const GONE2 = "UNRUNNABLE: tests/hooks/gone2.js (missing: test file)";
const PESTER = "UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)";

caseBegin("count-missing-file-lines", "hooks/lib/missing-test-files.js");
test("count-missing-file-lines", () => {
  const M = load();
  const cases = [
    { name: "two-plain-lines", text: `PASS: a\n${GONE}\n${GONE2}\nResults: PASS=1\n`, want: 2 },
    { name: "none", text: "PASS: a\nPASS: b\nResults: PASS=2\n", want: 0 },
    { name: "empty-text", text: "", want: 0 },
    { name: "runtime-only-line-not-counted", text: `${PESTER}\n`, want: 0 },
    { name: "mixed-runtime-and-file", text: `${PESTER}\n${GONE}\n`, want: 1 },
    { name: "crlf-split", text: `PASS: a\r\n${GONE}\r\n${GONE2}\r\n`, want: 2 },
    { name: "same-path-twice-counts-twice", text: `${GONE}\n${GONE}\n`, want: 2 },
    { name: "trailing-blank-tolerated", text: `${GONE} \t\n`, want: 1 },
    { name: "spoofed-neutralized-prefix-not-counted", text: `[run-all:neutralized] ${GONE}\n`, want: 0 },
    { name: "indented-line-not-counted", text: `  ${GONE}\n\t${GONE2}\n`, want: 0 },
    { name: "suffix-text-not-counted", text: `${GONE} extra\n`, want: 0 },
    { name: "path-with-blanks-counted", text: "UNRUNNABLE: tests/my dir/a b.sh (missing: test file)\n", want: 1 },
  ];
  // The caller splits on /\r?\n/ (the same split the hook and the worker use).
  for (const { name, text, want } of cases) {
    assert.strictEqual(M.countMissingFileLines(text.split(/\r?\n/)), want, name);
  }
  assert.strictEqual(M.countMissingFileLines([]), 0, "empty-array");
});
caseEnd();

caseBegin("summary-token", "hooks/lib/missing-test-files.js");
test("summary-token", () => {
  const M = load();
  const cases = [
    { name: "zero-is-null", n: 0, want: null },
    { name: "negative-is-null", n: -3, want: null },
    { name: "one", n: 1, want: "Missing test files: 1; " },
    { name: "many", n: 42, want: "Missing test files: 42; " },
    { name: "huge-clamped-to-nine-digits", n: 123456789012, want: "Missing test files: 999999999; " },
    { name: "nine-digit-max-kept", n: 999999999, want: "Missing test files: 999999999; " },
    { name: "ten-digit-boundary-clamped", n: 1000000000, want: "Missing test files: 999999999; " },
  ];
  for (const { name, n, want } of cases) {
    assert.strictEqual(M.summaryToken(n), want, name);
  }
});
caseEnd();

caseBegin("with-summary-token", "hooks/lib/missing-test-files.js");
test("with-summary-token", () => {
  const M = load();
  const base = "Missing runtimes: Pester>=5.0 (1 file); PASS=0 FAIL=0 SKIP=0 UNRUNNABLE=2";
  const cases = [
    { name: "zero-leaves-summary-unchanged", n: 0, summary: base, want: base },
    { name: "positive-prefixes-token-before-runtimes", n: 2, summary: base, want: `Missing test files: 2; ${base}` },
    { name: "positive-on-plain-summary", n: 1, summary: "worker run", want: "Missing test files: 1; worker run" },
  ];
  for (const { name, n, summary, want } of cases) {
    assert.strictEqual(M.withSummaryToken(summary, n), want, name);
  }
});
caseEnd();

caseBegin("read-summary-token", "hooks/lib/missing-test-files.js");
test("read-summary-token", () => {
  const M = load();
  const cases = [
    { name: "no-token-is-zero", summary: "Missing runtimes: python (1 files); PASS=0", want: 0 },
    { name: "empty-is-zero", summary: "", want: 0 },
    { name: "valid-token", summary: "Missing test files: 2; Missing runtimes: python (1 files)", want: 2 },
    { name: "token-only", summary: "Missing test files: 7; PASS=0 FAIL=0", want: 7 },
    { name: "overflow-reads-as-one", summary: "Missing test files: 9999999999; Missing runtimes: python", want: 1 },
    { name: "nine-digit-max", summary: "Missing test files: 999999999; PASS=0", want: 999999999 },
    { name: "ten-digit-boundary-reads-as-one", summary: "Missing test files: 1000000000; PASS=0", want: 1 },
    { name: "zero-token-reads-as-zero", summary: "Missing test files: 0; PASS=0", want: 0 },
    { name: "no-trailing-space-reads-as-one", summary: "Missing test files: 2;PASS=0", want: 1 },
    { name: "non-numeric-reads-as-one", summary: "Missing test files: many; Missing runtimes: python", want: 1 },
  ];
  for (const { name, summary, want } of cases) {
    assert.strictEqual(M.readSummaryToken(summary), want, name);
  }
});
caseEnd();

caseBegin("runtime-regexes-skip-the-token", "hooks/lib/missing-test-files.js");
test("runtime-regexes-skip-the-token", () => {
  const M = load();
  assert.ok(M.WORKER_MISSING_RE instanceof RegExp, "WORKER_MISSING_RE exported");
  assert.ok(M.SUMMARY_MISSING_RE instanceof RegExp, "SUMMARY_MISSING_RE exported");
  // A stateful `g` flag would make .exec() alternate between hit and miss across calls.
  assert.strictEqual(M.WORKER_MISSING_RE.flags.includes("g"), false, "WORKER_MISSING_RE has no g flag");
  assert.strictEqual(M.WORKER_MISSING_RE.flags.includes("m"), true, "WORKER_MISSING_RE is multiline");
  assert.strictEqual(M.SUMMARY_MISSING_RE.flags, "", "SUMMARY_MISSING_RE has no flags");
  const worker = [
    { name: "worker-legacy-quoted", text: "status: unrunnable\nsummary: 'Missing runtimes: Pester>=5.0 (2 files); PASS=3'\n", want: "Pester>=5.0 (2 files)" },
    { name: "worker-token-quoted", text: "status: unrunnable\nsummary: 'Missing test files: 2; Missing runtimes: Pester>=5.0 (1 file); PASS=0'\n", want: "Pester>=5.0 (1 file)" },
    { name: "worker-token-unquoted", text: "summary: Missing test files: 1; Missing runtimes: uv (1 file)\n", want: "uv (1 file)" },
    { name: "worker-non-numeric-token", text: "summary: 'Missing test files: many; Missing runtimes: uv (1 file)'\n", want: "uv (1 file)" },
    { name: "worker-token-only", text: "summary: 'Missing test files: 2; PASS=0 FAIL=0'\n", want: null },
    { name: "worker-no-summary-line", text: "Missing runtimes: uv (1 file)\n", want: null },
  ];
  for (const { name, text, want } of worker) {
    const m = M.WORKER_MISSING_RE.exec(text);
    assert.strictEqual(m ? m[1] : null, want, name);
  }
  const summary = [
    { name: "summary-legacy", text: "Missing runtimes: python (1 files); PASS=0", want: "python (1 files)" },
    { name: "summary-token", text: "Missing test files: 2; Missing runtimes: python (1 files); PASS=0", want: "python (1 files)" },
    { name: "summary-non-numeric-token", text: "Missing test files: many; Missing runtimes: python (1 files)", want: "python (1 files)" },
    { name: "summary-token-only", text: "Missing test files: 2; PASS=0", want: null },
    { name: "summary-runtimes-not-at-start", text: "PASS=0; Missing runtimes: python", want: null },
  ];
  for (const { name, text, want } of summary) {
    const m = M.SUMMARY_MISSING_RE.exec(text);
    assert.strictEqual(m ? m[1] : null, want, name);
  }
});
caseEnd();
