"use strict";
// Tests: hooks/workflow-run-tests.js
// Tags: TL2, hooks, run-tests, hit-attribution, scope:issue-specific
// Shared by every part of tests/bin/feature-2669-runner-hook-wiring.js. Loading it isolates the
// workflow dirs into one temp root (removed at exit) and drops the inherited session id.

const { isolate } = require("../../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2669-wiring-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
delete process.env.CLAUDE_CODE_SESSION_ID;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const ROOT_FWD = fwd(ROOT);
const HOOK = path.join(ROOT, "hooks", "workflow-run-tests.js");
const mod = (rel) => require(path.join(ROOT, rel));

const totals = { passed: 0, failed: 0 };
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
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

// seedPrefix(sid) — every step before run_tests complete, as a real session reaches run_tests.
function seedPrefix(sid) {
  const wf = mod("hooks/workflow-state");
  const approval = mod("hooks/workflow-state/completion-approval.js");
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "review_tests", "write_code"]) {
    if (approval.isApprovalGatedStep(s)) approval.recordPlanApproval(sid, s, { source: "reset-sentinel", reason: "2669 fixture" });
    wf.markStep(sid, s, "complete");
  }
}

// hook(sid, command, exitCode, stdout) — one PostToolUse call of the real hook, in a child.
function hook(sid, command, exitCode, stdout) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: ROOT_FWD }, tool_response: { exit_code: exitCode, stdout } };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), encoding: "utf8", timeout: 30000, env: process.env, cwd: TMP });
  if (r.error) throw new Error(`hook did not run: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`hook exit ${r.status}: ${r.stderr}`);
}

function runTests(sid) {
  const s = mod("hooks/workflow-state").readState(sid);
  return (s && s.steps && s.steps.run_tests) || {};
}

const errText = (e) => (e && e.message ? e.message : String(e));

// baselineCli(sid, worktree) — one run of the real bin/run-tests-baseline over sid's recorded state.
function baselineCli(sid, worktree) {
  const cache = path.join(TMP, `rtb-cache-${sid}`);
  fs.mkdirSync(cache, { recursive: true });
  const r = spawnSync("bash", [fwd(path.join(ROOT, "bin", "run-tests-baseline")), "--session", sid, "--worktree", worktree, "--per-test-timeout", "10"], {
    encoding: "utf8", timeout: 120000, env: Object.assign({}, process.env, { RUN_ALL_CACHE_DIR: fwd(cache) }), cwd: TMP,
  });
  return { status: r.status, stdout: (r.stdout || "").replace(/\r/g, ""), stderr: r.stderr || "", error: r.error ? r.error.message : null };
}

module.exports = { TMP, ROOT, ROOT_FWD, fwd, mod, totals, check, show, eq, seedPrefix, hook, runTests, errText, baselineCli };
