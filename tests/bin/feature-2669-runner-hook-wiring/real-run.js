"use strict";
// Tests: bin/worker-dispatch/workers/test-runner.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/dispatch-outcome.js, bin/run-tests-baseline
// Tags: TL2, bin, hooks, worker-dispatch, run-tests, baseline, hit-attribution, integration, scope:issue-specific
// The real dispatcher runs the real tests/run-all.sh over fixture tests that reach the command
// guard; the real run_tests hook reads what it left (outcome file and dispatcher stdout), and the
// real bin/run-tests-baseline reads the state that hook recorded. Nothing on the way is hand-made.

const { gitInit } = require("../../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { TMP, ROOT, fwd, mod, check, show, eq, seedPrefix, hook, runTests, errText, baselineCli } = require("./common");

const FIX = path.join(TMP, "fixrepo");
const FIX_FWD = fwd(FIX);
const DISPATCH = path.join(ROOT, "bin", "worker-dispatch.js");

function git(args) {
  const r = spawnSync("git", ["-C", FIX].concat(args), { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr || r.error}`);
}

// A fixture repo with this branch's runner and libraries, bash and node tests only.
function buildFixture() {
  fs.mkdirSync(path.join(FIX, "tests", "bin"), { recursive: true });
  gitInit(FIX);
  fs.cpSync(path.join(ROOT, "bin"), path.join(FIX, "bin"), { recursive: true });
  fs.cpSync(path.join(ROOT, "hooks"), path.join(FIX, "hooks"), { recursive: true });
  fs.cpSync(path.join(ROOT, "tests", "lib"), path.join(FIX, "tests", "lib"), { recursive: true });
  // The runner's root decoy reads the retired names from this file; it is not run here.
  fs.copyFileSync(path.join(ROOT, "tests", "bin", "feature-2561-root-names-residue.sh"), path.join(FIX, "tests", "bin", "feature-2561-root-names-residue.sh"));
  fs.copyFileSync(path.join(ROOT, "tests", "run-all.sh"), path.join(FIX, "tests", "run-all.sh"));
  // Host lanes and the duration ledger key on the real HOME; the fixture runs without them.
  for (const f of ["test-host-lanes.sh", "run-all-durations.sh"]) fs.rmSync(path.join(FIX, "bin", "lib", f), { force: true });
  const reg = path.join(FIX, "hooks", "lib", "test-language-registry.json");
  const t = JSON.parse(fs.readFileSync(reg, "utf8"));
  t.entries = t.entries.filter((e) => e.id !== "pester" && e.id !== "pytest");
  fs.writeFileSync(reg, JSON.stringify(t, null, 2));
  // The header is composed so that this file carries one frontmatter header only.
  const fixture = (name, body) => fs.writeFileSync(path.join(FIX, "tests", "bin", name),
    ["#!/usr/bin/env bash", `# ${"Tests"}: none`].concat(body, ["exit 0", ""]).join("\n"));
  fixture("hit-guard.sh", ["gh --version >/dev/null 2>&1 || true"]);
  fixture("hit-noid.sh", ["env -u ROOT_DECOY_TEST_ID gh --version >/dev/null 2>&1 || true"]);
  fixture("clean.sh", [":"]);
  git(["add", "-A"]);
  git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--no-verify", "-m", "fixture"]);
}

// dispatch(sid, tests, seq) — the real dispatcher over a payload in sid's control dir.
function dispatch(sid, tests, seq = 1) {
  const stem = `worker-test-runner-${seq}`;
  const dir = mod("hooks/workflow-state/state-io/control-dir.js").getSessionControlDir(sid);
  fs.mkdirSync(dir, { recursive: true });
  const payload = path.join(dir, `${stem}.json`);
  fs.writeFileSync(payload, JSON.stringify({ cwd: FIX_FWD, test_args: tests, timeout_seconds: 70 }));
  const r = spawnSync(process.execPath, [DISPATCH, "test-runner", FIX_FWD, fwd(payload)], {
    encoding: "utf8", timeout: 80000, env: process.env, cwd: TMP,
  });
  let outcome = null;
  try { outcome = JSON.parse(fs.readFileSync(path.join(dir, `${stem}.outcome.json`), "utf8")); } catch (_) { /* checked below */ }
  return {
    command: `node "${fwd(DISPATCH)}" test-runner "${FIX_FWD}" "${fwd(payload)}"`,
    stdout: r.stdout || "", status: r.status, error: r.error ? r.error.message : null, outcome,
  };
}

// One real run per verdict; its file route and its stdout route each land in their own session.
function wire(tag, tests) {
  const fileSid = `s-2669-w-${tag}-file`;
  const outSid = `s-2669-w-${tag}-out`;
  seedPrefix(fileSid);
  seedPrefix(outSid);
  const d = dispatch(fileSid, tests);
  hook(fileSid, "git status", 0, "");
  hook(outSid, d.command, d.status === null ? 1 : d.status, d.stdout);
  return { d, sids: { file: fileSid, out: outSid }, file: runTests(fileSid), out: runTests(outSid) };
}

// baseline(sid) — the real baseline CLI over what the hook recorded for sid, run once per sid.
const baselineSeen = {};
function baseline(sid) {
  if (!baselineSeen[sid]) baselineSeen[sid] = baselineCli(sid, FIX_FWD);
  return baselineSeen[sid];
}

const HIT_TESTS = ["tests/bin/hit-guard.sh", "tests/bin/hit-noid.sh", "tests/bin/clean.sh"];
const CLEAN_TESTS = ["tests/bin/clean.sh"];

// A hit run, then a clean run, in ONE session: each a real dispatch the real hook ingests.
function sequence() {
  const sid = "s-2669-w-seq";
  seedPrefix(sid);
  const first = dispatch(sid, HIT_TESTS, 1);
  hook(sid, "git status", 0, "");
  const afterHit = runTests(sid);
  const d = dispatch(sid, CLEAN_TESTS, 2);
  hook(sid, "git status", 0, "");
  return { d: first.error !== null ? first : d, afterHit, afterClean: runTests(sid) };
}

let hit = null;
let clean = null;
let seq = null;
let setupError = null;
function prepare() {
  try {
    buildFixture();
    hit = wire("hit", HIT_TESTS);
    clean = wire("clean", CLEAN_TESTS);
    seq = sequence();
  } catch (e) {
    setupError = errText(e);
  }
}
const ready = (w) => (setupError !== null ? `setup failed: ${setupError}` : (w.d.error !== null ? `dispatcher: ${w.d.error}` : null));
const ROUTES = [["file route", "file"], ["stdout route", "out"]];
const NOID_PREFIX = "command-guard (no test id) gh";
const HIT_CONTRACT = { pass: 2, fail: 1, skip: 0, executed: 3, unrunnable: 0, timeout: 0, hits: 1 };
const lines = (s) => s.split("\n");

function withHits() {
  check("wiring: the dispatcher ran and wrote its outcome file", () => {
    const why = ready(hit);
    if (why) return why;
    if (hit.d.outcome === null) return `no outcome file; stdout: ${hit.d.stdout.slice(0, 300)}`;
    return undefined;
  });
  check("wiring: the worker's contract charges the guard hit to its test and counts the other as HITS", () => {
    if (ready(hit)) return ready(hit);
    eq(hit.d.outcome && hit.d.outcome.worker_result.run_contract, HIT_CONTRACT, "outcome run_contract");
    return undefined;
  });
  check("wiring: the worker's failing_tests names only the test that reached the stub under its id", () => {
    if (ready(hit)) return ready(hit);
    eq(hit.d.outcome && hit.d.outcome.worker_result.failing_tests, ["tests/bin/hit-guard.sh"], "outcome failing_tests");
    return undefined;
  });
  check("wiring: the worker's hits list holds the one hit without a test id", () => {
    if (ready(hit)) return ready(hit);
    const h = hit.d.outcome && hit.d.outcome.worker_result.hits;
    if (!Array.isArray(h) || h.length !== 1 || !String(h[0]).startsWith(NOID_PREFIX)) return `outcome hits: ${show(h)}`;
    return undefined;
  });
  for (const [label, key] of ROUTES) {
    check(`wiring: ${label} — the run is recorded as failing`, () => {
      if (ready(hit)) return ready(hit);
      eq(hit[key].run_outcome, "fail", "run_outcome");
      return undefined;
    });
    check(`wiring: ${label} — failing_tests is the guard test alone`, () => {
      if (ready(hit)) return ready(hit);
      eq(hit[key].failing_tests, ["tests/bin/hit-guard.sh"], "failing_tests");
      return undefined;
    });
    check(`wiring: ${label} — hit_count is 1`, () => {
      if (ready(hit)) return ready(hit);
      eq(hit[key].hit_count, 1, "hit_count");
      return undefined;
    });
    check(`wiring: ${label} — hit_summary is the worker's hits list`, () => {
      if (ready(hit)) return ready(hit);
      const s = hit[key].hit_summary;
      if (!Array.isArray(s) || s.length !== 1 || !String(s[0]).startsWith(NOID_PREFIX)) return `hit_summary: ${show(s)}`;
      eq(s, hit.d.outcome && hit.d.outcome.worker_result.hits, "hit_summary vs outcome hits");
      return undefined;
    });
  }
  check("wiring: the file route ingested this dispatch's outcome file", () => {
    if (ready(hit)) return ready(hit);
    const src = hit.file.outcome_source;
    eq(src && src.stem, "worker-test-runner-1", "outcome_source.stem");
    return undefined;
  });
}

function withoutHits() {
  check("control: the dispatcher reports a pass", () => {
    if (ready(clean)) return ready(clean);
    eq(clean.d.outcome && clean.d.outcome.status, "pass", "outcome status");
    eq(clean.d.status, 0, "dispatcher exit");
    return undefined;
  });
  for (const [label, key] of ROUTES) {
    check(`control: ${label} — run_tests completes with a pass`, () => {
      if (ready(clean)) return ready(clean);
      eq([clean[key].status, clean[key].run_outcome], ["complete", "pass"], "status, run_outcome");
      return undefined;
    });
    check(`control: ${label} — no hit count or summary is left`, () => {
      if (ready(clean)) return ready(clean);
      const e = clean[key];
      if (e.hit_count !== undefined && e.hit_count !== null && e.hit_count !== 0) return `hit_count ${show(e.hit_count)}`;
      if (Array.isArray(e.hit_summary) && e.hit_summary.length > 0) return `hit_summary ${show(e.hit_summary)}`;
      return undefined;
    });
  }
}

// A later clean run in the same session tombstones both hit fields: recordPass writes them as
// null, and a null annotation drops the key from the projected entry.
function hitThenCleanInOneSession() {
  check("sequence: the hit run leaves hit_count 1 and its hits list in the session", () => {
    if (ready(seq)) return ready(seq);
    const e = seq.afterHit;
    eq([e.status, e.hit_count], ["pending", 1], "status, hit_count after the hit run");
    if (!Array.isArray(e.hit_summary) || e.hit_summary.length !== 1 || !String(e.hit_summary[0]).startsWith(NOID_PREFIX)) return `hit_summary: ${show(e.hit_summary)}`;
    return undefined;
  });
  check("sequence: the clean run in the same session completes run_tests with a pass", () => {
    if (ready(seq)) return ready(seq);
    const e = seq.afterClean;
    eq([e.status, e.run_outcome], ["complete", "pass"], "status, run_outcome");
    eq(e.outcome_source && e.outcome_source.stem, "worker-test-runner-2", "outcome_source.stem");
    return undefined;
  });
  check("sequence: the clean run clears hit_count and hit_summary instead of carrying them over", () => {
    if (ready(seq)) return ready(seq);
    if (seq.afterHit.hit_count === undefined) return "precondition: the hit run left no hit_count to clear";
    const e = seq.afterClean;
    if ("hit_count" in e) return `hit_count carried over: ${show(e.hit_count)}`;
    if ("hit_summary" in e) return `hit_summary carried over: ${show(e.hit_summary)}`;
    return undefined;
  });
}

// C2: the baseline CLI reads the worker-produced run (both routes) and stops at its hit.
function baselineOnRealRun() {
  for (const [label, key] of ROUTES) {
    const cli = () => baseline(hit.sids[key]);
    check(`baseline: ${label} — the CLI over the worker's run exits 6 although a failing list exists`, () => {
      if (ready(hit)) return ready(hit);
      const r = cli();
      if (r.error) return `CLI did not run: ${r.error}`;
      eq(r.status, 6, `CLI exit (stdout: ${r.stdout.slice(0, 300)} stderr: ${r.stderr.slice(0, 300)})`);
      return undefined;
    });
    check(`baseline: ${label} — the CLI prints BASELINE_HITS: count=1`, () => {
      if (ready(hit)) return ready(hit);
      if (!lines(cli().stdout).includes("BASELINE_HITS: count=1")) return `stdout: ${cli().stdout.slice(0, 300)}`;
      return undefined;
    });
    check(`baseline: ${label} — the CLI prints the worker's hit as a HIT line`, () => {
      if (ready(hit)) return ready(hit);
      const h = lines(cli().stdout).filter((l) => l.startsWith("HIT: "));
      if (h.length !== 1 || !h[0].includes(NOID_PREFIX)) return `HIT lines: ${show(h)}`;
      return undefined;
    });
    check(`baseline: ${label} — nothing is classified and run_tests stays pending`, () => {
      if (ready(hit)) return ready(hit);
      const classified = lines(cli().stdout).filter((l) => /^BASELINE(_SUMMARY)?: /.test(l));
      if (classified.length > 0) return `classified: ${show(classified)}`;
      eq(runTests(hit.sids[key]).status, "pending", "run_tests status");
      return undefined;
    });
    check(`baseline: control — ${label} — the CLI over the clean run has no hits to report`, () => {
      if (ready(clean)) return ready(clean);
      const r = baseline(clean.sids[key]);
      if (r.error) return `CLI did not run: ${r.error}`;
      eq(r.status, 3, "CLI exit (no failing list)");
      if (/^BASELINE_HITS:/m.test(r.stdout)) return `stdout: ${r.stdout.slice(0, 300)}`;
      return undefined;
    });
  }
}

module.exports = { prepare, withHits, withoutHits, hitThenCleanInOneSession, baselineOnRealRun, FIX, git, wire, baseline, ROUTES };
