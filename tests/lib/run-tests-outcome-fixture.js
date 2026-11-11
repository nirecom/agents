"use strict";
// Tests: tests/lib/run-tests-outcome-fixture.js
// Tags: test-infrastructure, shared-lib, run-tests, fixture, scope:common
// tests/lib/run-tests-outcome-fixture.js — shared fixture for the #2472 / #2688 / #2803 js tests.
// Seeds run_tests state directly (never through MARK_STEP / --advance, which now refuse a
// completion without run evidence), places trusted worker outcome files, drives the real
// run_tests hook and the real CLIs in child processes, and builds fixture git repos.
// setup(prefix) must run before any hook or CLI: it pins the workflow dirs (harness isolate),
// an empty transcript dir, and drops the inherited session id.

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { isolate, gitInit } = require("./harness");

const ROOT = path.join(__dirname, "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const ROOT_FWD = fwd(ROOT);
const HOOK = path.join(ROOT, "hooks", "workflow-run-tests.js");
const mod = (rel) => require(path.join(ROOT, rel));

let TMP = null;
function setup(prefix) {
  const restore = isolate();
  TMP = fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
  fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
  delete process.env.CLAUDE_CODE_SESSION_ID;
  delete process.env.CLAUDE_PROJECT_DIR;
  process.on("exit", () => {
    restore();
    fs.rmSync(TMP, { recursive: true, force: true });
  });
  return TMP;
}
const tmp = () => TMP;

// check / eq tally PASS:/FAIL: lines; noNewFailures turns the tally into the case verdict.
const totals = { passed: 0, failed: 0 };
const errText = (e) => (e && e.message ? e.message : String(e));
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = errText(e);
  }
  if (why === null) {
    totals.passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    totals.failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}

const PREFIX_STEPS = ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "review_tests", "write_code"];

// seedPrefix(sid) — a fresh raw v2 state file with every step before run_tests complete. The
// prefix is a precondition here, not the subject, so it is written past appendEvents and the
// glossary / approval boundaries that guard a live completion of those steps.
function seedPrefix(sid) {
  const at = new Date().toISOString();
  const events = PREFIX_STEPS.map((step, i) => ({
    kind: "step_status", step, status: "complete", provenance: "observed", origin: "test-fixture", at, seq: i + 1,
  }));
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), JSON.stringify({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: TMP, git_branch: "feature/fixture" },
    workflow_type: "wf-code", deliverable_type: "wf-code", events,
  }, null, 2));
}

// seed(sid, events) — raw events appended as the store's own writers would leave them.
function seed(sid, events) {
  mod("hooks/workflow-state/state-io/events").appendEvents(sid, events.map((e) =>
    Object.assign({ provenance: "observed", origin: "run-tests-hook" }, e)));
}
const status = (step, value, extra) => Object.assign({ kind: "step_status", step, status: value }, extra || {});
const note = (key, value, extra) => Object.assign({ kind: "step_annotation", step: "run_tests", key, value }, extra || {});

function state(sid) {
  return mod("hooks/workflow-state").readState(sid) || {};
}
const runTests = (sid) => ((state(sid).steps || {}).run_tests) || {};
const eventCount = (sid) => (state(sid).events || []).length;

// hook(sid, command, exitCode, stdout, cwd) — one PostToolUse call of the real hook, in a child.
function hook(sid, command, exitCode, stdout, cwd) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: cwd || ROOT_FWD }, tool_response: { exit_code: exitCode, stdout } };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), encoding: "utf8", timeout: 30000, env: process.env, cwd: TMP });
  if (r.error) throw new Error(`hook did not run: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`hook exit ${r.status}: ${r.stderr}`);
  return r.stdout || "";
}

const controlDir = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`);
const BASE_MTIME = Math.floor(Date.now() / 1000) - 3600;

// placeOutcome(sid, o) — writes worker-test-runner-<seq>.{json,dispatched,outcome.json} as the
// dispatcher leaves them; ingest happens on the next hook call. o: { seq, cwd, testArgs, status,
// exitCode, contract: {pass, fail, skip, unrunnable, timeout, hits?}, failing, hits, summary }.
function placeOutcome(sid, o) {
  const stem = `worker-test-runner-${o.seq}`;
  const dir = controlDir(sid);
  fs.mkdirSync(dir, { recursive: true });
  const cwd = o.cwd || ROOT_FWD;
  const payload = Buffer.from(`${JSON.stringify({ cwd, timeout_seconds: 120, test_args: o.testArgs || [] })}\n`, "utf8");
  fs.writeFileSync(path.join(dir, `${stem}.json`), payload);
  const marker = path.join(dir, `${stem}.dispatched`);
  fs.writeFileSync(marker, `${new Date().toISOString()}\n`);
  const t = BASE_MTIME + Number(o.seq) * 10;
  fs.utimesSync(marker, t, t);
  const c = Object.assign({ pass: 0, fail: 0, skip: 0, unrunnable: 0, timeout: 0 }, o.contract || {});
  const runContract = { pass: c.pass, fail: c.fail, skip: c.skip, executed: c.pass + c.fail + c.skip, unrunnable: c.unrunnable, timeout: c.timeout };
  const hits = o.hits || [];
  if (hits.length > 0 || c.hits !== undefined) runContract.hits = c.hits !== undefined ? c.hits : hits.length;
  const st = o.status || (c.fail > 0 || c.unrunnable > 0 || hits.length > 0 ? "fail" : "pass");
  const workerResult = {
    run_contract: runContract,
    failing_tests: o.failing || [],
    log_tail: [`Results: PASS=${c.pass}  FAIL=${c.fail}  SKIP=${c.skip}`],
    summary: o.summary || `${st}: ${c.pass} passed, ${c.fail} failed`,
  };
  if (hits.length > 0) workerResult.hits = hits;
  if (o.failingExits) workerResult.failing_exits = o.failingExits;
  const outcome = {
    schema_version: 1, worker: "test-runner", stem, session_id: sid,
    payload_sha256: crypto.createHash("sha256").update(payload).digest("hex"),
    cwd, status: st, exit_code: o.exitCode !== undefined ? o.exitCode : (st === "pass" ? 0 : 1), duration_ms: 1200,
    worker_result: workerResult,
  };
  fs.writeFileSync(path.join(dir, `${stem}.outcome.json`), `${JSON.stringify(outcome)}\n`);
  return stem;
}
const isIngested = (sid, stem) => fs.existsSync(path.join(controlDir(sid), `${stem}.ingested`));

// run(file, args, opts) — one child run of a repo entrypoint. It launches with node by default;
// pass `node: false` for a bash entrypoint.
function run(rel, args, opts) {
  const o = opts || {};
  const abs = path.join(ROOT, rel);
  const isNode = o.node !== false;
  const argv = isNode ? [abs].concat(args || []) : [fwd(abs)].concat(args || []);
  const r = spawnSync(isNode ? process.execPath : "bash", argv, {
    encoding: "utf8", timeout: o.timeout || 60000, cwd: o.cwd || TMP, input: o.input || "",
    env: Object.assign({}, process.env, o.env || {}),
  });
  return { status: r.status, stdout: (r.stdout || "").replace(/\r/g, ""), stderr: r.stderr || "", error: r.error ? r.error.message : null };
}

// advance(sid, step, flag) — bin/workflow/next-step --advance, as the model issues it.
function advance(sid, step, flag, extra) {
  return run("bin/workflow/next-step", ["--session", sid, "--advance", "--step", step, flag || "--complete"].concat(extra || []));
}

function git(dir, args) {
  const r = spawnSync("git", ["-C", dir].concat(args), { encoding: "utf8", timeout: 30000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return (r.stdout || "").trim();
}

// makeRepo(name, files, opts) — a fixture repo with `files` committed on opts.branch
// (default main). opts.topic checks out a topic branch after the commit.
function makeRepo(name, files, opts) {
  const o = opts || {};
  const dir = path.join(TMP, name);
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  git(dir, ["config", "user.email", "t@example.invalid"]);
  git(dir, ["config", "user.name", "t"]);
  git(dir, ["checkout", "-q", "-b", o.branch || "main"]);
  writeFiles(dir, Object.assign({ "README.md": "fixture\n" }, files || {}));
  git(dir, ["add", "-A"]);
  git(dir, ["commit", "-q", "-m", "base"]);
  if (o.topic) git(dir, ["checkout", "-q", "-b", o.topic]);
  return fwd(dir);
}
function writeFiles(dir, files) {
  for (const [rel, body] of Object.entries(files)) {
    const p = path.join(dir, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
  }
}

module.exports = {
  ROOT, ROOT_FWD, fwd, mod, setup, tmp, totals, check, eq, show, errText,
  seedPrefix, seed, status, note, state, runTests, eventCount, hook, controlDir,
  placeOutcome, isIngested, run, advance, git, makeRepo, writeFiles,
};
