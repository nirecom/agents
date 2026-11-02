"use strict";
// Tests: hooks/lib/decision-time-limit.js, hooks/lib/limited-child-process.js, hooks/workflow-gate/code-size-gate.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, decision-time-limit, subprocess, commit-gate, code-size, scope:issue-specific
// #2849 / #2781: the decision time limit can be widened by WORKFLOW_DECISION_TIME_LIMIT_MS, and a
// caller that declares failOpenOnTimeout keeps its own shorter child timeout (code-size-gate).
// TL1 swaps child_process for recording stubs under a fake clock
// (feature-2676-hook-timeout-relation/fake-process.js); TL2 runs feature-2849-decision-budget/driver.js.
// TL3 gap (what this test does NOT catch):
// - that the commit-push worker's gate child really receives the env and a real commit passes
// Closest-to-action mitigation: tests/bin/feature-2849-gate-verdict.js (the env handed to the gate child).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
// An in-process arm registers the decision timing log's exit listener: keep its write off ~/.agents.
const stateRoot = fs.mkdtempSync(path.join(os.tmpdir(), "decision-budget-"));
process.env.AGENTS_STATE_DIR = stateRoot;
const fakes = require("./feature-2676-hook-timeout-relation/fake-process");
after(() => {
  restore();
  process.on("exit", () => fs.rmSync(stateRoot, { recursive: true, force: true }));
});

const LIMIT_ENV = "WORKFLOW_DECISION_TIME_LIMIT_MS";
const DEFAULT_LIMIT_MS = 10000;
const MIN_SLICE_MS = require("../../hooks/lib/hook-deadline").MIN_SLICE_MS;

// ---- resolveDecisionLimitMs(env) ----------------------------------------------------------
const VALID = [["2000", 2000], ["110000", 110000], ["1", 1]];
const FALLBACK = [["absent", undefined], ["empty", ""], ["zero", "0"], ["negative", "-5"],
  ["non-numeric", "abc"], ["fraction", "1.5"], ["blank", "  "], ["trailing text", "2000ms"]];

caseBegin("decision-limit-default-stays-10000", "hooks/lib/decision-time-limit.js");
test("DECISION_TIME_LIMIT_MS stays 10000", () => {
  assert.strictEqual(require("../../hooks/lib/decision-time-limit").DECISION_TIME_LIMIT_MS, DEFAULT_LIMIT_MS);
});
caseEnd();

caseBegin("resolve-decision-limit-valid-env", "hooks/lib/decision-time-limit.js");
test("resolveDecisionLimitMs: a positive integer in the env is the limit", () => {
  const { resolveDecisionLimitMs } = require("../../hooks/lib/decision-time-limit");
  assert.strictEqual(typeof resolveDecisionLimitMs, "function", "resolveDecisionLimitMs is exported");
  for (const [raw, want] of VALID) assert.strictEqual(resolveDecisionLimitMs({ [LIMIT_ENV]: raw }), want, raw);
});
caseEnd();

caseBegin("resolve-decision-limit-invalid-env-falls-back", "hooks/lib/decision-time-limit.js");
test("resolveDecisionLimitMs: absent, empty, 0, negative, non-numeric or fractional -> 10000", () => {
  const { resolveDecisionLimitMs } = require("../../hooks/lib/decision-time-limit");
  assert.strictEqual(typeof resolveDecisionLimitMs, "function", "resolveDecisionLimitMs is exported");
  for (const [label, raw] of FALLBACK) {
    const env = raw === undefined ? {} : { [LIMIT_ENV]: raw };
    assert.strictEqual(resolveDecisionLimitMs(env), DEFAULT_LIMIT_MS, label);
  }
});
caseEnd();

// Number() would accept these; the contract is digits only, so each falls back.
const NON_CANONICAL = [["leading space", " 2000"], ["exponent", "2e3"], ["hex", "0x7D0"], ["plus sign", "+2000"]];
caseBegin("resolve-decision-limit-non-canonical-forms-fall-back", "hooks/lib/decision-time-limit.js");
test("resolveDecisionLimitMs: ' 2000', '2e3', '0x7D0', '+2000' -> 10000", () => {
  const { resolveDecisionLimitMs } = require("../../hooks/lib/decision-time-limit");
  assert.strictEqual(typeof resolveDecisionLimitMs, "function", "resolveDecisionLimitMs is exported");
  for (const [label, raw] of NON_CANONICAL) {
    assert.strictEqual(resolveDecisionLimitMs({ [LIMIT_ENV]: raw }), DEFAULT_LIMIT_MS, `${label} (${JSON.stringify(raw)})`);
  }
});
caseEnd();

caseBegin("resolve-decision-limit-huge-value-is-finite", "hooks/lib/decision-time-limit.js");
test("resolveDecisionLimitMs: a huge value still yields a finite positive limit", () => {
  const { resolveDecisionLimitMs } = require("../../hooks/lib/decision-time-limit");
  assert.strictEqual(typeof resolveDecisionLimitMs, "function", "resolveDecisionLimitMs is exported");
  const got = resolveDecisionLimitMs({ [LIMIT_ENV]: "9".repeat(400) });
  assert.ok(Number.isFinite(got) && got > 0, `finite and positive: ${got}`);
});
caseEnd();

// ---- TL2 driver ---------------------------------------------------------------------------
const DRIVER = path.join(__dirname, "feature-2849-decision-budget", "driver.js");
// drive(args, limitValue) -> { status, stderr, lines, wallMs }: limitValue undefined leaves the env out.
function drive(args, limitValue) {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  delete env[LIMIT_ENV];
  if (limitValue !== undefined) env[LIMIT_ENV] = limitValue;
  const startMs = Date.now();
  const done = childProcess.spawnSync(process.execPath, [DRIVER, ...args],
    { env, cwd: os.tmpdir(), encoding: "utf8", timeout: 60000 });
  const lines = String(done.stdout || "").split("\n").filter((l) => l.trim() !== "").map((l) => JSON.parse(l));
  return { status: done.status, stderr: String(done.stderr || ""), lines, wallMs: Date.now() - startMs };
}
const askOf = (lines) => lines.find((l) => l.hookSpecificOutput);
const reasonOf = (lines) => {
  const ask = askOf(lines);
  assert.ok(ask, `an ask was written: ${JSON.stringify(lines)}`);
  assert.strictEqual(ask.hookSpecificOutput.permissionDecision, "ask");
  return ask.hookSpecificOutput.permissionDecisionReason;
};

caseBegin("armed-limit-follows-env", "hooks/lib/decision-time-limit.js");
test("TL2 arm with WORKFLOW_DECISION_TIME_LIMIT_MS=2000: time left <= 2000 and the reason names 2000 ms", () => {
  const done = drive(["limit"], "2000");
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  assert.ok(done.lines[0].remaining <= 2000, `time left at arm: ${done.lines[0].remaining}`);
  assert.ok(reasonOf(done.lines).includes("(2000 ms)"), reasonOf(done.lines));
});
caseEnd();

caseBegin("armed-limit-default-without-env", "hooks/lib/decision-time-limit.js");
test("TL2 arm without the env, or with an invalid one: the limit stays 10000 ms", () => {
  for (const value of [undefined, "abc", "0", "-1"]) {
    const done = drive(["limit"], value);
    assert.strictEqual(done.status, 0, `driver exit for ${value} (stderr: ${done.stderr})`);
    assert.ok(done.lines[0].remaining > 2000 && done.lines[0].remaining <= DEFAULT_LIMIT_MS, `time left for ${value}: ${done.lines[0].remaining}`);
    assert.ok(reasonOf(done.lines).includes(`(${DEFAULT_LIMIT_MS} ms)`), `${value}: ${reasonOf(done.lines)}`);
  }
});
caseEnd();

// ---- limited-child-process: failOpenOnTimeout (TL1) ---------------------------------------
function stubSpawn(behaviour) {
  const calls = [];
  const saved = { spawnSync: childProcess.spawnSync, execSync: childProcess.execSync, execFileSync: childProcess.execFileSync };
  for (const name of Object.keys(saved)) {
    childProcess[name] = (...args) => {
      const options = args.find((arg, index) => index > 0 && arg && typeof arg === "object" && !Array.isArray(arg)) || {};
      calls.push({ name, options: { ...options } });
      return behaviour(name, options);
    };
  }
  return { calls, restoreStubs: () => Object.assign(childProcess, saved) };
}
const okResult = () => ({ status: 0, stdout: "", stderr: "", error: undefined });
const timedOut = () => ({ status: null, signal: "SIGTERM", stdout: "", stderr: "",
  error: Object.assign(new Error("spawnSync bash ETIMEDOUT"), { code: "ETIMEDOUT" }) });

function setup({ armed = true, spentMs = 0, behaviour = okResult } = {}) {
  const fake = fakes.fakeProcess();
  const stubs = stubSpawn(behaviour);
  const { modules, error } = fakes.freshRequire(fake, ["decision-time-limit.js", "limited-child-process.js"]);
  const lib = modules["limited-child-process.js"];
  const limit = modules["decision-time-limit.js"];
  if (!lib || !limit) {
    stubs.restoreStubs();
    assert.fail(`hooks/lib modules load (${error && error.message})`);
  }
  if (armed) fakes.withFake(fake, () => limit.armDecisionTimeLimit(fakes.armOptions(fake, "workflow-gate")));
  fake.nowMs += spentMs;
  return { lib, limit, fake, calls: stubs.calls, done: stubs.restoreStubs };
}
const spawnWith = (ctx, options) =>
  fakes.runCaught(ctx.fake, () => ctx.lib.spawnSync("bash", ["bin/review-code-size", "--staged"], options));

caseBegin("declared-timeout-shorter-than-left-is-kept", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout + timeout 3000 with 10000 left: the child timeout is 3000", () => {
  const ctx = setup();
  try {
    const done = spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.strictEqual(ctx.calls.length, 1, "the child is started once");
    assert.strictEqual(ctx.calls[0].options.timeout, 3000);
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-key-not-passed-to-child-process", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout: the declaration key does not reach child_process", () => {
  const ctx = setup();
  try {
    spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.strictEqual(ctx.calls.length, 1, "the child is started once");
    assert.ok(!("failOpenOnTimeout" in ctx.calls[0].options), `options reaching child_process: ${Object.keys(ctx.calls[0].options)}`);
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-caller-timeout-returns-result", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout: the caller's own timeout firing first returns the ETIMEDOUT result, no ask", () => {
  const ctx = setup({ behaviour: timedOut });
  try {
    const done = spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.strictEqual(done.exited, false, "no ask, the caller decides");
    assert.deepStrictEqual(ctx.fake.written, []);
    assert.strictEqual(done.value.status, null);
    assert.strictEqual(done.value.error && done.value.error.code, "ETIMEDOUT");
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-time-left-shorter-asks", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout + timeout 3000 with 2000 left: the child gets 2000 and its timeout asks", () => {
  const ctx = setup({ spentMs: DEFAULT_LIMIT_MS - 2000, behaviour: timedOut });
  try {
    const done = spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [2000]);
    assert.deepStrictEqual([done.exited, done.code], [true, 0]);
    assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("undeclared-short-timeout-still-asks", "hooks/lib/limited-child-process.js");
test("armed, no declaration (N1): a short caller timeout is replaced by the time left and a timeout asks", () => {
  const ctx = setup({ behaviour: timedOut });
  try {
    const done = spawnWith(ctx, { timeout: MIN_SLICE_MS + 50 });
    assert.ifError(done.thrown);
    assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [DEFAULT_LIMIT_MS]);
    assert.deepStrictEqual([done.exited, done.code], [true, 0], "never falls open to allow");
    assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-without-timeout-keeps-old-behaviour", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout without a caller timeout: the child gets the time left and a timeout asks", () => {
  const ctx = setup({ behaviour: timedOut });
  try {
    const done = spawnWith(ctx, { failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [DEFAULT_LIMIT_MS]);
    assert.deepStrictEqual([done.exited, done.code], [true, 0]);
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-unarmed-passes-timeout-through", "hooks/lib/limited-child-process.js");
test("not armed, failOpenOnTimeout + timeout 3000: the caller's timeout reaches child_process unchanged", () => {
  const ctx = setup({ armed: false, spentMs: 3600 * 1000 });
  try {
    const done = spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.strictEqual(done.exited, false);
    assert.deepStrictEqual(ctx.calls.map((c) => [c.name, c.options.timeout]), [["spawnSync", 3000]]);
  } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-timeout-equal-to-left-asks", "hooks/lib/limited-child-process.js");
test("armed, failOpenOnTimeout + timeout 3000 with exactly 3000 left: the timeout asks (the limit owns a tie)", () => {
  const ctx = setup({ spentMs: DEFAULT_LIMIT_MS - 3000, behaviour: timedOut });
  try {
    const done = spawnWith(ctx, { timeout: 3000, failOpenOnTimeout: true });
    assert.ifError(done.thrown);
    assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [3000]);
    assert.deepStrictEqual([done.exited, done.code], [true, 0]);
    assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
  } finally { ctx.done(); }
});
caseEnd();

// ---- CPR-ORTH: execFileSync / execSync share the declaration contract ---------------------
// Armed, both reach child_process through file-stdio's spawnSync; a timeout surfaces as a throw.
const execFileWith = (ctx, options) =>
  fakes.runCaught(ctx.fake, () => ctx.lib.execFileSync("bash", ["bin/review-code-size", "--staged"], options));
const execWith = (ctx, options) =>
  fakes.runCaught(ctx.fake, () => ctx.lib.execSync("bash bin/review-code-size --staged", options));

function assertDeclaredThrows(ctx, done) {
  assert.strictEqual(done.exited, false, "no ask, the caller decides");
  assert.deepStrictEqual(ctx.fake.written, []);
  assert.strictEqual(done.thrown && done.thrown.code, "ETIMEDOUT", `thrown: ${done.thrown}`);
  assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [3000]);
  assert.ok(!("failOpenOnTimeout" in ctx.calls[0].options), `options reaching child_process: ${Object.keys(ctx.calls[0].options)}`);
}
function assertUndeclaredAsks(ctx, done) {
  assert.ifError(done.thrown);
  assert.deepStrictEqual(ctx.calls.map((c) => c.options.timeout), [DEFAULT_LIMIT_MS]);
  assert.deepStrictEqual([done.exited, done.code], [true, 0], "never falls open");
  assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
}

caseBegin("exec-file-declared-caller-timeout-throws", "hooks/lib/limited-child-process.js");
test("execFileSync armed, failOpenOnTimeout + timeout 3000: the caller's timeout throws ETIMEDOUT, no ask", () => {
  const ctx = setup({ behaviour: timedOut });
  try { assertDeclaredThrows(ctx, execFileWith(ctx, { timeout: 3000, failOpenOnTimeout: true })); } finally { ctx.done(); }
});
caseEnd();

caseBegin("exec-file-undeclared-short-timeout-asks", "hooks/lib/limited-child-process.js");
test("execFileSync armed, no declaration: a short caller timeout is replaced by the time left and asks", () => {
  const ctx = setup({ behaviour: timedOut });
  try { assertUndeclaredAsks(ctx, execFileWith(ctx, { timeout: MIN_SLICE_MS + 50 })); } finally { ctx.done(); }
});
caseEnd();

caseBegin("exec-declared-caller-timeout-throws", "hooks/lib/limited-child-process.js");
test("execSync armed, failOpenOnTimeout + timeout 3000: the caller's timeout throws ETIMEDOUT, no ask", () => {
  const ctx = setup({ behaviour: timedOut });
  try { assertDeclaredThrows(ctx, execWith(ctx, { timeout: 3000, failOpenOnTimeout: true })); } finally { ctx.done(); }
});
caseEnd();

caseBegin("exec-undeclared-short-timeout-asks", "hooks/lib/limited-child-process.js");
test("execSync armed, no declaration: a short caller timeout is replaced by the time left and asks", () => {
  const ctx = setup({ behaviour: timedOut });
  try { assertUndeclaredAsks(ctx, execWith(ctx, { timeout: MIN_SLICE_MS + 50 })); } finally { ctx.done(); }
});
caseEnd();

caseBegin("declared-key-not-passed-when-unarmed", "hooks/lib/limited-child-process.js");
test("not armed: the declaration key reaches child_process from none of spawnSync / execFileSync / execSync", () => {
  const ctx = setup({ armed: false });
  try {
    const options = { timeout: 3000, failOpenOnTimeout: true };
    for (const run of [spawnWith, execFileWith, execWith]) assert.ifError(run(ctx, { ...options }).thrown);
    assert.deepStrictEqual(ctx.calls.map((c) => c.name), ["spawnSync", "execFileSync", "execSync"]);
    for (const call of ctx.calls) {
      assert.ok(!("failOpenOnTimeout" in call.options), `${call.name} options: ${Object.keys(call.options)}`);
      assert.strictEqual(call.options.timeout, 3000, `${call.name} keeps the caller's timeout`);
    }
  } finally { ctx.done(); }
});
caseEnd();

// ---- TL2: real children -------------------------------------------------------------------
caseBegin("tl2-declared-hang-returns-at-caller-timeout", "hooks/lib/limited-child-process.js");
test("TL2 armed, failOpenOnTimeout + timeout 500 on a hung child: ETIMEDOUT returned well before the limit", () => {
  const done = drive(["declared-hang", "500"]);
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  assert.strictEqual(askOf(done.lines), undefined, `no ask: ${JSON.stringify(done.lines)}`);
  assert.strictEqual(done.lines[0].returned.error, "ETIMEDOUT");
  assert.ok(done.lines[0].elapsedMs < 5000, `returned after ${done.lines[0].elapsedMs} ms`);
});
caseEnd();

const repoDir = fs.mkdtempSync(path.join(stateRoot, "repo-"));

caseBegin("code-size-gate-hang-fails-open", "hooks/workflow-gate/code-size-gate.js");
test("TL2 code-size-gate, review-code-size hangs: fails open at its own 3000 ms, not an ask at 10 s", () => {
  const done = drive(["code-size", "hang", repoDir]);
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  assert.strictEqual(askOf(done.lines), undefined, `no ask: ${JSON.stringify(done.lines)}`);
  assert.deepStrictEqual(done.lines[0].result, { action: "ok" });
  assert.ok(done.stderr.includes("failing open"), done.stderr);
  assert.ok(done.lines[0].elapsedMs < 8000, `decided after ${done.lines[0].elapsedMs} ms`);
});
caseEnd();

caseBegin("code-size-gate-hard-still-blocks", "hooks/workflow-gate/code-size-gate.js");
test("TL2 code-size-gate, review-code-size reports HARD: block with the HARD line", () => {
  const done = drive(["code-size", "hard", repoDir]);
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  const { result } = done.lines[0];
  assert.strictEqual(result.action, "block");
  assert.ok(result.reason.includes("  HARD: bin/big.js"), result.reason);
});
caseEnd();

caseBegin("code-size-gate-short-limit-asks", "hooks/workflow-gate/code-size-gate.js");
test("TL2 code-size-gate with WORKFLOW_DECISION_TIME_LIMIT_MS=2000, review-code-size hangs: ask at the limit", () => {
  const done = drive(["code-size", "hang", repoDir], "2000");
  assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
  assert.ok(reasonOf(done.lines).includes("decision time limit"), reasonOf(done.lines));
  assert.ok(done.wallMs < 6000, `asked after ${done.wallMs} ms`);
});
caseEnd();
