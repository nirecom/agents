"use strict";
// Tests: settings.json, hooks/lib/decision-time-limit.js
// Tags: TL1, hooks, pretooluse, allow-deny-hook, non-allow-deny-hook, decision-time-limit, settings, timeout, scope:issue-specific, deadline, timing-log, TL2
// #2676 / #2540 Step 6: allow-deny hook registrations share one settings.json timeout, longer than
// the decision time limit, so a hook out of decision time answers "ask" before Claude Code cancels it.
// Step 3 (decision-time-limit-* cases): the limit is anchored at process start; the clock and the
// output are faked (feature-2676-hook-timeout-relation/fake-process.js).
// TL3 gap (what this test does NOT catch):
// - host launch delay before the hook's clock starts; that the ask becomes a permission prompt
// Closest-to-action mitigation: tests/hooks/TL3-hook-timeout-window.sh (case A6 for the ask).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
// The in-process arm calls below register the timing-log exit listener in this process too, so
// AGENTS_STATE_DIR stays pinned to the end and the temp root goes in an exit listener added later.
const stateRoot = fs.mkdtempSync(path.join(os.tmpdir(), "decision-timing-"));
process.env.AGENTS_STATE_DIR = path.join(stateRoot, "own-process");
after(() => {
  restore();
  process.on("exit", () => fs.rmSync(stateRoot, { recursive: true, force: true }));
});
const table = require("./feature-2676-hook-classification/table");
const fakes = require("./feature-2676-hook-timeout-relation/fake-process");

// PR #2747 raised every PreToolUse hook timeout to 15 s; each non-allow-deny hook keeps that value
// (Step 6 changes only each allow-deny hook). KNOWN_NON_ALLOW_DENY keeps the check from passing on an
// empty set.
const NON_ALLOW_DENY_TIMEOUT = 15;
const KNOWN_NON_ALLOW_DENY = ["rtk-rewrite", "subagent-dispatch-prompt", "show-user-verified-context", "jev-shadow-pre"];

function allowDenyNames() {
  const { rows, error } = table.readClassification();
  assert.ok(!error, error || "");
  return new Set(rows.filter((row) => row.kind === "allow-deny").flatMap((row) => row.hooks));
}
function allowDenyRegistrations() {
  const names = allowDenyNames();
  const regs = table.registrations().filter((reg) => names.has(reg.hook));
  assert.ok(regs.length > 0, "at least one allow-deny hook registration");
  return regs;
}
function decisionTimeLimitMs() {
  let lib = null;
  let loadError = null;
  try { lib = require(path.join(table.REPO, "hooks", "lib", "decision-time-limit.js")); } catch (err) { loadError = err; }
  assert.ok(lib, `hooks/lib/decision-time-limit.js loads (${loadError && loadError.message})`);
  assert.ok(Number.isFinite(lib.DECISION_TIME_LIMIT_MS) && lib.DECISION_TIME_LIMIT_MS > 0, "DECISION_TIME_LIMIT_MS is a positive number");
  return lib.DECISION_TIME_LIMIT_MS;
}

caseBegin("allow-deny-timeouts-equal", "settings.json");
test("every allow-deny hook registration has the same timeout", () => {
  const regs = allowDenyRegistrations();
  const values = [...new Set(regs.map((reg) => reg.timeout))];
  assert.strictEqual(values.length, 1,
    `one timeout shared by every allow-deny hook; found ${regs.map((reg) => `${reg.hook}=${reg.timeout}`).join(", ")}`);
  assert.ok(Number.isFinite(values[0]) && values[0] > 0, "the timeout is a positive number of seconds");
});

test(`every non-allow-deny hook registration has the ${NON_ALLOW_DENY_TIMEOUT} s timeout`, () => {
  const names = allowDenyNames();
  const regs = table.registrations().filter((reg) => !names.has(reg.hook));
  for (const hookName of KNOWN_NON_ALLOW_DENY) {
    assert.ok(regs.some((reg) => reg.hook === hookName), `${hookName} is registered as a non-allow-deny hook`);
  }
  const off = regs.filter((reg) => reg.timeout !== NON_ALLOW_DENY_TIMEOUT);
  assert.deepStrictEqual(off.map((reg) => `${reg.hook || reg.command}=${reg.timeout}`), [],
    `every non-allow-deny PreToolUse registration has timeout ${NON_ALLOW_DENY_TIMEOUT}`);
});
caseEnd();

caseBegin("timeout-over-decision-limit", "hooks/lib/decision-time-limit.js");
test("the allow-deny hook timeout is longer than DECISION_TIME_LIMIT_MS", () => {
  const limitMs = decisionTimeLimitMs();
  for (const reg of allowDenyRegistrations()) {
    assert.ok(reg.timeout * 1000 > limitMs, `${reg.hook}: timeout ${reg.timeout} s > ${limitMs} ms`);
  }
});

// The ask after the limit still has to be written and the process ended before Claude Code cancels it.
const MIN_MARGIN_MS = 5000;
test(`the allow-deny hook timeout leaves at least ${MIN_MARGIN_MS} ms after DECISION_TIME_LIMIT_MS`, () => {
  const limitMs = decisionTimeLimitMs();
  for (const reg of allowDenyRegistrations()) {
    const marginMs = reg.timeout * 1000 - limitMs;
    assert.ok(marginMs >= MIN_MARGIN_MS, `${reg.hook}: margin ${marginMs} ms >= ${MIN_MARGIN_MS} ms`);
  }
});

test("DECISION_TIME_LIMIT_MS is 10 s: exactly 5 s before the 15 s allow-deny hook timeout", () => {
  const limitMs = decisionTimeLimitMs();
  assert.strictEqual(limitMs, 10000);
  for (const reg of allowDenyRegistrations()) {
    assert.strictEqual(reg.timeout * 1000 - limitMs, 5000, `${reg.hook}: timeout ${reg.timeout} s`);
  }
});
caseEnd();

function freshLimit(fake) {
  const { modules, error } = fakes.freshRequire(fake, ["decision-time-limit.js"]);
  assert.ok(modules["decision-time-limit.js"], `hooks/lib/decision-time-limit.js loads (${error && error.message})`);
  return modules["decision-time-limit.js"];
}
const arm = (lib, fake, hookName) => fakes.withFake(fake, () => lib.armDecisionTimeLimit(fakes.armOptions(fake, hookName)));
const remaining = (lib, fake) => fakes.withFake(fake, () => lib.remainingDecisionMs());
const check = (lib, fake, checkName) => fakes.runCaught(fake, () => lib.checkDecisionTime(checkName));
const reasonOf = (fake) => fakes.writtenJson(fake).hookSpecificOutput.permissionDecisionReason;

caseBegin("decision-time-limit-clock", "hooks/lib/decision-time-limit.js");
test("DECISION_TIME_LIMIT_MS is a positive finite number of milliseconds", () => {
  const lib = freshLimit(fakes.fakeProcess());
  assert.strictEqual(typeof lib.DECISION_TIME_LIMIT_MS, "number");
  assert.ok(Number.isFinite(lib.DECISION_TIME_LIMIT_MS) && lib.DECISION_TIME_LIMIT_MS > 0);
});

test("remaining time counts down from process start, not from the arm call", () => {
  const fake = fakes.fakeProcess({ uptimeSec: 0.5 });
  const lib = freshLimit(fake);
  arm(lib, fake, "example-hook");
  assert.strictEqual(remaining(lib, fake), lib.DECISION_TIME_LIMIT_MS - 500, "500 ms of uptime already spent");
  fake.nowMs += 300;
  assert.strictEqual(remaining(lib, fake), lib.DECISION_TIME_LIMIT_MS - 800);
});

test("a second arm call is a no-op: the first hook name and start stay", () => {
  const fake = fakes.fakeProcess();
  const lib = freshLimit(fake);
  arm(lib, fake, "first-hook");
  fake.nowMs += 400;
  arm(lib, fake, "second-hook");
  assert.strictEqual(remaining(lib, fake), lib.DECISION_TIME_LIMIT_MS - 400, "the deadline did not move");
  fake.nowMs += lib.DECISION_TIME_LIMIT_MS;
  check(lib, fake, "example check");
  assert.ok(reasonOf(fake).startsWith("first-hook: "), `reason keeps the first hook name: ${reasonOf(fake)}`);
});
caseEnd();

caseBegin("decision-time-limit-check", "hooks/lib/decision-time-limit.js");
test("checkDecisionTime does nothing before the limit", () => {
  const fake = fakes.fakeProcess();
  const lib = freshLimit(fake);
  arm(lib, fake, "example-hook");
  fake.nowMs += lib.DECISION_TIME_LIMIT_MS - 1;
  const done = check(lib, fake, "example check");
  assert.ifError(done.thrown);
  assert.strictEqual(done.exited, false, "the process goes on");
  assert.deepStrictEqual(fake.written, [], "nothing written");
});

test("checkDecisionTime past the limit writes ask and ends the process with 0", () => {
  const fake = fakes.fakeProcess();
  const lib = freshLimit(fake);
  arm(lib, fake, "example-hook");
  fake.nowMs += lib.DECISION_TIME_LIMIT_MS + 50;
  const done = check(lib, fake, "staged file scan");
  assert.ifError(done.thrown);
  assert.deepStrictEqual([done.exited, done.code], [true, 0]);
  const out = fakes.writtenJson(fake);
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
  assert.strictEqual(out.hookSpecificOutput.hookEventName, "PreToolUse");
  assert.ok(!("decision" in out), "ask carries no legacy decision key");
});

test("the ask reason names the hook, the limit and the unfinished check", () => {
  const fake = fakes.fakeProcess();
  const lib = freshLimit(fake);
  arm(lib, fake, "scan-outbound");
  fake.nowMs += lib.DECISION_TIME_LIMIT_MS + 1;
  check(lib, fake, "git show");
  assert.strictEqual(reasonOf(fake),
    `scan-outbound: decision time limit (${lib.DECISION_TIME_LIMIT_MS} ms) reached before git show finished; asking instead of deciding`);
});

test("boundary: remaining exactly 0 asks", () => {
  const fake = fakes.fakeProcess();
  const lib = freshLimit(fake);
  arm(lib, fake, "example-hook");
  fake.nowMs += lib.DECISION_TIME_LIMIT_MS;
  assert.strictEqual(remaining(lib, fake), 0);
  assert.strictEqual(check(lib, fake, "example check").exited, true);
});

test("not armed: checkDecisionTime is a no-op even long after start", () => {
  const fake = fakes.fakeProcess({ uptimeSec: 3600 });
  const lib = freshLimit(fake);
  const done = check(lib, fake, "example check");
  assert.ifError(done.thrown);
  assert.strictEqual(done.exited, false);
  assert.deepStrictEqual(fake.written, []);
});
caseEnd();

// Decision timing log: one JSONL line per armed process, written at exit (real child processes).
const timing = require("./feature-2676-hook-timeout-relation/timing-run");
const { decisionOf, onlyLine, assertFields, assertSameOutcome } = timing;
const runChild = (mode, options) => timing.runChild(stateRoot, mode, options);
const unwritableStateDir = () => timing.unwritableStateDir(stateRoot);

caseBegin("decision-timing-log", "hooks/lib/decision-time-limit.js");
test("an armed process that exits normally writes one line with all six fields", () => {
  const run = runChild("normal");
  const line = onlyLine(run);
  assert.strictEqual(decisionOf(run), "allow", "the decision on stdout is untouched");
  assertFields(line, run);
  assert.strictEqual(line.asked, false);
});

test("a wait after arm shows in exitAtMs - armedAtMs, and startedAt is the child's start", () => {
  const run = runChild("delay");
  const line = onlyLine(run);
  assertFields(line, run);
  assert.strictEqual(run.info.delayMs, 300);
  assert.ok(line.exitAtMs - line.armedAtMs >= run.info.delayMs,
    `exitAtMs - armedAtMs = ${line.exitAtMs - line.armedAtMs} ms >= the ${run.info.delayMs} ms wait`);
  assert.ok(line.startedAt <= run.endedAt - run.info.delayMs, "the child started before its own wait");
});

test("two armed processes on one state dir leave two lines: the log is appended, not replaced", () => {
  const first = runChild("normal");
  const second = runChild("normal", { stateDir: first.agentsStateDir });
  assert.strictEqual(second.status, 0, `stderr: ${second.stderr}`);
  assert.ok(Array.isArray(second.lines), `log file at ${second.logPath}`);
  assert.deepStrictEqual(second.lines.map((line) => line.pid), [first.pid, second.pid]);
});

test("exitAtMs is captured before the write: not later than the next exit listener's uptime", () => {
  const run = runChild("normal");
  const line = onlyLine(run);
  assert.ok(run.info, `child reported its INFO line (stderr: ${run.stderr})`);
  assert.ok(line.exitAtMs <= run.info.uptimeAtLastExitListenerMs,
    `exitAtMs ${line.exitAtMs} <= uptime in a later exit listener ${run.info.uptimeAtLastExitListenerMs}`);
});

for (const mode of ["ask", "check-late"]) {
  test(`${mode}: the ask is still on stdout with exit 0, and the line says asked=true`, () => {
    const run = runChild(mode);
    const line = onlyLine(run);
    const out = JSON.parse(run.stdout.trim());
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask", `stdout: ${run.stdout}`);
    assert.strictEqual(run.stdout.trim().split("\n").length, 1, "only the ask is written");
    assert.strictEqual(line.asked, true);
    assert.strictEqual(line.hookName, "x-hook");
    assert.strictEqual(line.pid, run.pid);
  });
}

test("never armed: nothing is written", () => {
  const run = runChild("unarmed");
  assert.strictEqual(run.status, 0, `stderr: ${run.stderr}`);
  assert.strictEqual(decisionOf(run), "allow");
  assert.strictEqual(run.lines, null, `no log file at ${run.logPath}`);
  assert.strictEqual(run.info.listenersAfter, run.info.listenersBefore, "no exit listener added");
});

test("a second arm call adds no exit listener and no second line", () => {
  const run = runChild("double");
  const line = onlyLine(run);
  assert.strictEqual(run.info.listenersAfter - run.info.listenersBefore, 1, "exactly one exit listener for two arm calls");
  assert.strictEqual(line.hookName, "x-hook", "the first arm call's hook name");
});
caseEnd();

caseBegin("decision-timing-log-failure", "hooks/lib/decision-time-limit.js");
// A state dir under a regular file cannot be created; the append stub throws outright.
// Each failure x {allow then exit 0, ask, allow then exit 2} must match the run without it.
const failures = [
  ["unwritable log dir", () => ({ stateDir: unwritableStateDir() })],
  ["append throws", () => ({ stub: true })],
];
const outcomes = [["normal", 0, "allow"], ["ask", 0, "ask"], ["exit2", 2, "allow"]];
for (const [label, failingOptions] of failures) {
  for (const [mode, status, decision] of outcomes) {
    test(`${label}, ${mode}: decision ${decision} and exit code ${status} match the writable case`, () => {
      const good = runChild(mode);
      const bad = runChild(mode, failingOptions());
      assert.deepStrictEqual([good.status, decisionOf(good)], [status, decision], `stderr: ${good.stderr}`);
      assertSameOutcome(good, bad);
    });
  }
}
caseEnd();
