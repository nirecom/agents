"use strict";
// Tests: bin/worker-dispatch/workers/test-runner.js, hooks/workflow-run-tests.js, bin/run-tests-baseline, bin/lib/run-all-hits.sh, bin/lib/run-all-worktree-change-detect.sh
// Tags: TL2, bin, hooks, worker-dispatch, run-tests, baseline, hit-attribution, root-decoy, worktree-change-detection, integration, scope:issue-specific
// The other hit kinds through the same real route as the command guard case in real-run.js:
// a test that changes a tracked file of the fixture checkout (worktree change) and tests that
// reach the root decoy, each dispatched for real, ingested by the real hook, read by the real CLI.

const fs = require("fs");
const path = require("path");
const { check, show, eq, runTests, errText } = require("./common");
const { FIX, git, wire, baseline, ROUTES } = require("./real-run");

const WCD_DATA = "wcd-data.txt";
const DECOY_STUB = "main/hooks/lib/load-env.js";
const DECOY_REACH = [
  "if grep -q '^ROOT_DECOY_MARKER=main$' \"${AGENTS_MAIN_ROOT:-/nonexistent}/.env\" 2>/dev/null; then",
  "  PREFIX node \"$AGENTS_MAIN_ROOT/hooks/lib/load-env.js\" >/dev/null 2>&1 || true",
  "fi",
];

// The header is composed so that this file carries one frontmatter header only.
function fixture(name, body) {
  fs.writeFileSync(path.join(FIX, "tests", "bin", name), ["#!/usr/bin/env bash", `# ${"Tests"}: none`].concat(body, ["exit 0", ""]).join("\n"));
}

function buildFixtures() {
  fs.writeFileSync(path.join(FIX, WCD_DATA), "clean\n");
  // Pure bash: the path comes from the script's own location, no guarded command on the way.
  fixture("wcd-tracked.sh", ["printf 'more\\n' >>\"${BASH_SOURCE[0]%/*}/../../" + WCD_DATA + "\""]);
  fixture("hit-decoy.sh", DECOY_REACH.map((l) => l.replace("PREFIX ", "")));
  fixture("hit-decoy-noid.sh", DECOY_REACH.map((l) => l.replace("PREFIX ", "env -u ROOT_DECOY_TEST_ID ")));
  git(["add", "-A"]);
  git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--no-verify", "-m", "hit kinds"]);
}

let wcd = null;
let decoy = null;
let wcdChanged = null;
let setupError = null;
function prepare() {
  try {
    buildFixtures();
    wcd = wire("wcd", ["tests/bin/wcd-tracked.sh"]);
    wcdChanged = fs.readFileSync(path.join(FIX, WCD_DATA), "utf8").replace(/\r/g, "");
    // Later runs start from a clean checkout again.
    git(["checkout", "--", WCD_DATA]);
    decoy = wire("decoy", ["tests/bin/hit-decoy.sh", "tests/bin/hit-decoy-noid.sh", "tests/bin/clean.sh"]);
  } catch (e) {
    setupError = errText(e);
  }
}
const ready = (w) => (setupError !== null ? `setup failed: ${setupError}` : (w === null ? "not run" : (w.d.error !== null ? `dispatcher: ${w.d.error}` : null)));
const lines = (s) => s.split("\n");

// expect: { contract, failing (worker failing_tests or undefined to skip), isHit(line) → bool }
function hitKind(label, w, expect) {
  const theHit = (list) => Array.isArray(list) && list.length === 1 && expect.isHit(String(list[0]));
  const workerHits = () => w && w.d.outcome && w.d.outcome.worker_result.hits;
  const c = (name, fn) => check(`${label}: ${name}`, () => ready(w) || fn());
  c("the dispatcher ran and wrote its outcome file", () => (w.d.outcome === null ? `no outcome file; stdout: ${w.d.stdout.slice(0, 300)}` : undefined));
  c("the worker's contract counts the hit as HITS=1", () => eq(w.d.outcome && w.d.outcome.worker_result.run_contract, expect.contract, "outcome run_contract"));
  if (expect.failing !== undefined) {
    c("the worker's failing_tests names only the test that reached it under its id", () => eq(w.d.outcome && w.d.outcome.worker_result.failing_tests, expect.failing, "outcome failing_tests"));
  }
  c("the worker's hits list holds the one unattributed hit", () => (theHit(workerHits()) ? undefined : `outcome hits: ${show(workerHits())}`));
  for (const [rl, key] of ROUTES) {
    c(`${rl} — the run is recorded as failing`, () => eq(w[key].run_outcome, "fail", "run_outcome"));
    c(`${rl} — hit_count is 1`, () => eq(w[key].hit_count, 1, "hit_count"));
    c(`${rl} — hit_summary is the worker's hits list and names the hit`, () => {
      const s = w[key].hit_summary;
      if (!theHit(s)) return `hit_summary: ${show(s)}`;
      eq(s, workerHits(), "hit_summary vs outcome hits");
      return undefined;
    });
    if (expect.failing !== undefined) {
      c(`${rl} — failing_tests is the attributed test alone`, () => eq(w[key].failing_tests, expect.failing, "failing_tests"));
    }
    const cli = () => baseline(w.sids[key]);
    c(`baseline: ${rl} — the CLI exits 6`, () => {
      const r = cli();
      if (r.error) return `CLI did not run: ${r.error}`;
      eq(r.status, 6, `CLI exit (stdout: ${r.stdout.slice(0, 300)} stderr: ${r.stderr.slice(0, 300)})`);
      return undefined;
    });
    c(`baseline: ${rl} — the CLI prints BASELINE_HITS: count=1`, () => (lines(cli().stdout).includes("BASELINE_HITS: count=1") ? undefined : `stdout: ${cli().stdout.slice(0, 300)}`));
    c(`baseline: ${rl} — the CLI prints the hit as its one HIT line`, () => {
      const h = lines(cli().stdout).filter((l) => l.startsWith("HIT: "));
      return h.length === 1 && expect.isHit(h[0].slice(5)) ? undefined : `HIT lines: ${show(h)}`;
    });
    c(`baseline: ${rl} — nothing is classified and run_tests stays pending`, () => {
      const classified = lines(cli().stdout).filter((l) => /^BASELINE(_SUMMARY)?: /.test(l));
      if (classified.length > 0) return `classified: ${show(classified)}`;
      eq(runTests(w.sids[key]).status, "pending", "run_tests status");
      return undefined;
    });
  }
}

// C1: a tracked file changed during the run is one unattributed hit that names the path.
function worktreeChangeHit() {
  check("wcd: the fixture test changed the tracked file", () => ready(wcd) || eq(wcdChanged, "clean\nmore\n", WCD_DATA));
  hitKind("wcd", wcd, {
    contract: { pass: 1, fail: 0, skip: 0, executed: 1, unrunnable: 0, timeout: 0, hits: 1 },
    failing: undefined,
    isHit: (l) => l.startsWith("worktree-change ") && l.includes("kind=tracked") && l.includes(`paths=${WCD_DATA}`),
  });
}

// C2: the root decoy, symmetric with the command guard case — the hit under a test id is that
// test's FAIL, the hit without one is HITS, and the CLI stops at it.
function rootDecoyHit() {
  hitKind("decoy", decoy, {
    contract: { pass: 2, fail: 1, skip: 0, executed: 3, unrunnable: 0, timeout: 0, hits: 1 },
    failing: ["tests/bin/hit-decoy.sh"],
    isHit: (l) => l.startsWith(`root-decoy (no test id) ${DECOY_STUB}`),
  });
}

module.exports = { prepare, worktreeChangeHit, rootDecoyHit };
