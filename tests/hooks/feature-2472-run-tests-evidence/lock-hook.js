"use strict";
// Tests: hooks/workflow-run-tests.js
// Tags: TL2, hooks, run-tests, state-lock, fail-closed, scope:issue-specific
// #3073 C1: the real PostToolUse hook, run while another process (lock-child.js hold) keeps the
// state lock, fails closed: the stdout route may take run_tests away but never grant it.

const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../../lib/run-tests-outcome-fixture");
const L = require("./lock");
const { check, eq } = F;

// One PostToolUse call of the real hook (hooks/workflow-run-tests.js) for a green run-all run.
const GREEN_STDOUT = "PASS: tests/a.sh\nRUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0\n";
function hookCall(sid) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command: `bash ${F.ROOT_FWD}/tests/run-all.sh`, cwd: F.ROOT_FWD }, tool_response: { exit_code: 0, stdout: GREEN_STDOUT } };
  const r = spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "workflow-run-tests.js")], { input: JSON.stringify(input), encoding: "utf8", timeout: L.WAIT_MS, cwd: F.tmp() });
  return { status: r.status, error: r.error ? r.error.message : null, stderr: (r.stderr || "").slice(0, 300) };
}

// The hook's lock-timeout catch: the stdout route may take run_tests away but never grant it.
async function hookLockTimeoutFailsClosed() {
  const control = L.scenario("hook-free");
  const free = hookCall(control.sid);
  check("C1 hook: fixture — the same green stdout alone completes run_tests when the lock is free", () => {
    eq(free.status, 0, `hook exit (${free.error || free.stderr})`);
    eq(F.runTests(control.sid).status, "complete", "status");
  });
  const s = L.scenario("hook");
  const stem = F.placeOutcome(s.sid, Object.assign({ seq: 1, cwd: s.cwd }, L.GREEN_FULL));
  const holder = L.child("hold", s);
  await L.until(L.fileAt(s.dir, "held"), "the holder to take the lock");
  const r = hookCall(s.sid);
  const marked = F.isIngested(s.sid, stem);
  L.touch(s.dir, "go");
  L.touch(s.dir, "release");
  await holder.done;
  check("C1 hook: the hook exits 0 although the state lock is held throughout", () => eq(r.status, 0, `hook exit (${r.error || r.stderr})`));
  check("C1 hook: run_tests is not complete and the outcome stays unconsumed", () => {
    if (F.runTests(s.sid).status === "complete") return "run_tests became complete";
    eq(marked, false, ".ingested");
    eq(L.unconsumed(s.sid), [stem], "unconsumed stems");
    return undefined;
  });
}

module.exports = { hookLockTimeoutFailsClosed };
