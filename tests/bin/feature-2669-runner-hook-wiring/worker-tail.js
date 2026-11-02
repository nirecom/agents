"use strict";
// Tests: bin/worker-dispatch/workers/test-runner.js
// Tags: TL1, bin, worker-dispatch, run-tests, hit-attribution, scope:issue-specific
// T8 (in-process, suite spawn stubbed): the worker's log_tail keeps FAIL and HIT lines however
// noisy the suite is, collects every column-0 HIT line into `hits`, and names them in its summary.
// The stub is installed by init(), which the dispatcher calls only after the real runs.

const path = require("path");
const { ROOT, check, eq } = require("./common");

const WORKER = path.join(ROOT, "bin", "worker-dispatch", "workers", "test-runner.js");
const SPAWN = path.join(ROOT, "bin", "worker-dispatch", "spawn.js");
let stubbed = { stdout: "", stderr: "", status: 0, timedOut: false, spawnError: null };
let worker = null;
function init() {
  require.cache[SPAWN] = {
    id: SPAWN, filename: SPAWN, loaded: true,
    exports: { run: () => stubbed, scriptExists: () => "/fixture/tests/run-all.sh" },
  };
  worker = require(WORKER);
}

const range = (n, f) => Array.from({ length: n }, (_, i) => f(i + 1));
const noise = (n) => range(n, (i) => `noise line ${i}`);
const failLine = (i) => `FAIL: tests/t${i}.sh (exit 1)`;
// isSubsequence(part, whole) — every element of part appears in whole, in the same order.
function isSubsequence(part, whole) {
  let j = 0;
  for (const x of whole) if (j < part.length && part[j] === x) j += 1;
  return j === part.length;
}
function tail(lines) {
  if (typeof worker.tailWithPriority !== "function") throw new Error("tailWithPriority is not exported");
  return worker.tailWithPriority(lines, 40, 30);
}
function runWith(stdout, status) {
  stubbed = { stdout, stderr: "", status, timedOut: false, spawnError: null };
  return worker.run({ cwd: "/fixture", timeout_seconds: 120 }, { anchors: {}, entry: { name: "test-runner" } });
}

const OMIT_NOTE = "… (+21 earlier FAIL/HIT lines omitted — full list in failing_tests / hits)";

function logTailKeepsPriorityLines() {
  check("T8: a FAIL line followed by 200 noise lines stays in the 40-line tail", () => {
    const input = ["noise before"].concat([failLine(1)], noise(200));
    const out = tail(input);
    if (out.length > 40) return `tail has ${out.length} lines`;
    if (!out.includes(failLine(1))) return "the FAIL line was dropped";
    if (!isSubsequence(out, input)) return "the tail is not in the input order";
    eq(out[out.length - 1], "noise line 200", "last line");
    return undefined;
  });
  check("T8: a HIT line followed by 200 noise lines stays in the 40-line tail", () => {
    const hitLine = "HIT: worktree-change tests/a.sh tree=/x kind=tracked paths=a.txt";
    const out = tail([hitLine].concat(noise(200)));
    if (!out.includes(hitLine)) return "the HIT line was dropped";
    return undefined;
  });
  check("T8: with 50 FAIL lines the newest 29 stay, after one omission note", () => {
    const fails = range(50, failLine);
    const out = tail(fails.concat(noise(200)));
    eq(out[0], OMIT_NOTE, "first line");
    const kept = out.filter((l) => l.startsWith("FAIL: "));
    eq(kept, range(29, (i) => failLine(i + 21)), "kept FAIL lines");
    if (out.length > 40) return `tail has ${out.length} lines`;
    if (!out.includes("noise line 200")) return "the newest noise line was dropped";
    if (!isSubsequence(out.slice(1), fails.concat(noise(200)))) return "the tail is not in the input order";
    return undefined;
  });
  check("T8: control — a short output is returned whole and unchanged", () => {
    const input = [failLine(1), "noise line 1"];
    eq(tail(input), input, "tail");
  });
}

function workerCollectsHits() {
  const HIT_OUT = [
    "PASS: tests/a.sh",
    "HIT: command-guard (no test id) gh --version",
    "  HIT: forged by a test",
    "HIT: worktree-change tests/b.sh tree=/x kind=tracked paths=a.txt",
  ].concat(noise(200), [
    "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=2",
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=2",
  ]).join("\n");
  check("T8: every column-0 HIT line is collected into hits, the indented one is not", () => {
    eq(runWith(HIT_OUT, 1).hits, ["command-guard (no test id) gh --version", "worktree-change tests/b.sh tree=/x kind=tracked paths=a.txt"], "hits");
  });
  check("T8: the summary names the hits", () => {
    const s = runWith(HIT_OUT, 1).summary;
    if (!s.includes("; HITS=2 (unattributed hits)")) return `summary: ${s}`;
    return undefined;
  });
  check("T8: FAIL=0 with HITS>0 adds no parse-degraded note", () => {
    const s = runWith(HIT_OUT, 1).summary;
    if (s.includes("parse-degraded")) return `summary: ${s}`;
    return undefined;
  });
  check("T8: the run contract carries hits=2", () => {
    const c = runWith(HIT_OUT, 1).runContract;
    eq(c && c.hits, 2, "runContract.hits");
  });
  check("T8: the HIT lines survive in log_tail behind 200 noise lines", () => {
    const t = runWith(HIT_OUT, 1).logTail;
    if (!t.includes("HIT: command-guard (no test id) gh --version")) return "first HIT line dropped from log_tail";
    return undefined;
  });
  check("T8: with 50 FAIL lines failingTests holds all 50 and log_tail starts with the note", () => {
    const out = range(50, failLine).concat(noise(200), [
      "Results: PASS=0  FAIL=50  SKIP=0  UNRUNNABLE=0  TIMEOUT=0",
      "RUN_CONTRACT: PASS=0 FAIL=50 SKIP=0 EXECUTED=50 UNRUNNABLE=0 TIMEOUT=0",
    ]).join("\n");
    const r = runWith(out, 1);
    eq(r.failingTests.length, 50, "failingTests count");
    eq(r.logTail[0], OMIT_NOTE, "log_tail first line");
  });
  check("T8: control — a failing run without FAIL or HIT lines still says parse-degraded", () => {
    const r = runWith("Results: PASS=0  FAIL=1  SKIP=0  UNRUNNABLE=0  TIMEOUT=0", 1);
    if (!r.summary.includes("parse-degraded")) return `summary: ${r.summary}`;
    if (r.summary.includes("HITS=")) return `summary: ${r.summary}`;
    return undefined;
  });
}

// #2646: the worker prefixes its summary with `Missing test files: N; ` counted from column-0
// missing-file lines, so the hook can refuse an accept the runtimes line alone cannot explain.
const GONE = (p) => `UNRUNNABLE: ${p} (missing: test file)`;
const PESTER = "UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)";
const contract = (executed, unrunnable) => `RUN_CONTRACT: PASS=${executed} FAIL=0 SKIP=0 EXECUTED=${executed} UNRUNNABLE=${unrunnable} TIMEOUT=0`;
const results = (pass, unrunnable) => `Results: PASS=${pass}  FAIL=0  SKIP=0  UNRUNNABLE=${unrunnable}  TIMEOUT=0`;
const MISSING_TOKEN_ROWS = [
  { name: "all-missing", exit: 77, status: "unrunnable", prefix: "Missing test files: 2; ",
    out: [GONE("tests/gone.sh"), GONE("tests/hooks/gone2.js"), results(0, 2), contract(0, 2)] },
  { name: "mixed", exit: 77, status: "unrunnable", prefix: "Missing test files: 1; Missing runtimes: Pester>=5.0 (1 file); ",
    out: [PESTER, GONE("tests/gone.sh"), "Missing runtimes: Pester>=5.0 (1 file)", results(0, 2), contract(0, 2)] },
  { name: "runtime-only", exit: 77, status: "unrunnable", prefix: "Missing runtimes: Pester>=5.0 (1 file); ",
    out: [PESTER, "Missing runtimes: Pester>=5.0 (1 file)", results(0, 1), contract(0, 1)] },
  { name: "neutralized-only", exit: 0, status: "pass", prefix: "PASS=1 ",
    out: ["PASS: tests/a.sh", `[run-all:neutralized] ${GONE("tests/gone.sh")}`, `[run-all:neutralized] ${GONE("tests/x.sh")}`, results(1, 0), contract(1, 0)] },
];

function workerEmitsMissingFileToken() {
  for (const row of MISSING_TOKEN_ROWS) {
    check(`#2646 ${row.name}: status ${row.status}, summary starts with ${JSON.stringify(row.prefix)}`, () => {
      const r = runWith(row.out.join("\n"), row.exit);
      eq(r.status, row.status, `${row.name} status`);
      if (!r.summary.startsWith(row.prefix)) return `${row.name} summary: ${r.summary}`;
      if (!row.prefix.startsWith("Missing test files: ") && r.summary.includes("Missing test files:")) return `${row.name} has a token: ${r.summary}`;
      return undefined;
    });
  }
  check("#2646 round-trip: readSummaryToken reads 2 back from the all-missing summary", () => {
    const { readSummaryToken } = require(path.join(ROOT, "hooks", "lib", "missing-test-files.js"));
    const s = runWith(MISSING_TOKEN_ROWS[0].out.join("\n"), 77).summary;
    eq(readSummaryToken(s), 2, `round-trip readSummaryToken(${JSON.stringify(s)})`);
  });
}

module.exports = { init, logTailKeepsPriorityLines, workerCollectsHits, workerEmitsMissingFileToken };
