"use strict";
// Tests: hooks/lib/limited-child-process.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, decision-time-limit, subprocess, scope:issue-specific
// #2676 / #2540 Step 3: spawnSync / execSync / execFileSync with the child timeout capped by the
// decision time left. TL1 swaps child_process for recording stubs and fakes the clock
// (feature-2676-hook-timeout-relation/fake-process.js); TL2 runs a real long-sleeping node child
// through feature-2676-limited-child-process/driver.js.
// TL3 gap (what this test does NOT catch):
// - that a hook cut at the limit still answers before the settings.json timeout on a loaded host
// Closest-to-action mitigation: tests/hooks/feature-2676-hook-classification.js (heavy-hook cases).
const { isolate } = require("../lib/harness");

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
// An in-process arm registers the decision timing log's exit listener: keep its write off ~/.agents
// to the very end, and remove the temp root in an exit listener added after every arm call.
const stateRoot = fs.mkdtempSync(path.join(os.tmpdir(), "decision-timing-"));
process.env.AGENTS_STATE_DIR = stateRoot;
const fakes = require("./feature-2676-hook-timeout-relation/fake-process");
after(() => {
  restore();
  process.on("exit", () => fs.rmSync(stateRoot, { recursive: true, force: true }));
});

const FNS = ["spawnSync", "execSync", "execFileSync"];
const MIN_SLICE_MS = require("../../hooks/lib/hook-deadline").MIN_SLICE_MS;

// stubChildProcess(behaviour) -> { calls, restoreStubs }: every child_process call is recorded
// and answered by behaviour(fnName, options) instead of starting a process.
function stubChildProcess(behaviour) {
  const calls = [];
  const saved = Object.fromEntries(FNS.map((name) => [name, childProcess[name]]));
  for (const name of FNS) {
    childProcess[name] = (...args) => {
      const options = args.find((arg, index) => index > 0 && arg && typeof arg === "object" && !Array.isArray(arg)) || {};
      calls.push({ name, args, timeout: options.timeout });
      return behaviour(name, options);
    };
  }
  return { calls, restoreStubs: () => Object.assign(childProcess, saved) };
}
const okResult = (name) => (name === "spawnSync" ? { status: 0, stdout: "", stderr: "", error: undefined } : "");
const timedOut = (name) => {
  const error = Object.assign(new Error("spawnSync ETIMEDOUT"), { code: "ETIMEDOUT" });
  if (name === "spawnSync") return { status: null, signal: "SIGTERM", stdout: "", stderr: "", error };
  throw error;
};

// setup({ armed, spentMs, behaviour }) -> { lib, limit, fake, calls, done }: a fresh, optionally
// armed copy of the wrapper whose clock has run spentMs since process start.
function setup({ armed = true, spentMs = 0, behaviour = okResult } = {}) {
  const fake = fakes.fakeProcess();
  const stubs = stubChildProcess(behaviour);
  const { modules, error } = fakes.freshRequire(fake, ["decision-time-limit.js", "limited-child-process.js"]);
  const lib = modules["limited-child-process.js"];
  const limit = modules["decision-time-limit.js"];
  if (!lib || !limit) {
    stubs.restoreStubs();
    assert.fail(`hooks/lib/limited-child-process.js and decision-time-limit.js load (${error && error.message})`);
  }
  if (armed) fakes.withFake(fake, () => limit.armDecisionTimeLimit(fakes.armOptions(fake, "example-hook")));
  fake.nowMs += spentMs;
  return { lib, limit, fake, calls: stubs.calls, done: stubs.restoreStubs };
}
const call = (ctx, name, timeout) => {
  const options = timeout === undefined ? {} : { timeout };
  const run = name === "execSync"
    ? () => ctx.lib.execSync("git show :a.txt", options)
    : () => ctx.lib[name]("git", ["show", ":a.txt", "--textconv"], options);
  return fakes.runCaught(ctx.fake, run);
};

for (const name of FNS) {
  test(`${name} not armed: the options reach child_process untouched`, () => {
    const ctx = setup({ armed: false, spentMs: 3600 * 1000 });
    try {
      for (const timeout of [undefined, 1234]) {
        const done = call(ctx, name, timeout);
        assert.ifError(done.thrown);
        assert.strictEqual(done.exited, false);
      }
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [undefined, 1234]);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.name), [name, name], "not routed through file-stdio spawnSync");
    } finally { ctx.done(); }
  });

  test(`${name} armed: the caller's timeout, longer or shorter, is replaced by the time left`, () => {
    const ctx = setup({ spentMs: 0 });
    try {
      const left = ctx.limit.DECISION_TIME_LIMIT_MS;
      const shorter = Math.max(MIN_SLICE_MS + 50, Math.floor(left / 2));
      for (const timeout of [undefined, left * 10, shorter]) call(ctx, name, timeout);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [left, left, left]);
    } finally { ctx.done(); }
  });

  test(`${name} armed with less than MIN_SLICE_MS left: no child, ask, exit 0`, () => {
    const ctx = setup();
    try {
      ctx.fake.nowMs += ctx.limit.DECISION_TIME_LIMIT_MS - (MIN_SLICE_MS - 1);
      const done = call(ctx, name, undefined);
      assert.ifError(done.thrown);
      assert.deepStrictEqual([done.exited, done.code], [true, 0]);
      assert.strictEqual(ctx.calls.length, 0, "the child is not started");
      const out = fakes.writtenJson(ctx.fake);
      assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
      assert.ok(out.hookSpecificOutput.permissionDecisionReason.includes("git show"),
        `check name from the command and its first args: ${out.hookSpecificOutput.permissionDecisionReason}`);
    } finally { ctx.done(); }
  });

  test(`${name} armed: a timeout from the time-left cap asks and ends the process`, () => {
    const ctx = setup({ behaviour: timedOut });
    try {
      const done = call(ctx, name, undefined);
      assert.ifError(done.thrown);
      assert.deepStrictEqual([done.exited, done.code], [true, 0]);
      assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
    } finally { ctx.done(); }
  });

  test(`${name} armed with the caller's shorter timeout: the child gets the time left, a timeout asks`, () => {
    const ctx = setup({ behaviour: timedOut });
    try {
      const left = ctx.limit.DECISION_TIME_LIMIT_MS;
      const done = call(ctx, name, MIN_SLICE_MS + 50);
      assert.strictEqual(ctx.calls.length, 1, "the child is started once");
      assert.strictEqual(ctx.calls[0].timeout, left, "the child timeout is the time left, not the caller's");
      assert.ifError(done.thrown);
      assert.deepStrictEqual([done.exited, done.code], [true, 0]);
      assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
    } finally { ctx.done(); }
  });

  test(`${name} armed after 3000 ms spent: the child timeout is the time left, not the full limit`, () => {
    const ctx = setup({ spentMs: 3000 });
    try {
      const left = ctx.limit.DECISION_TIME_LIMIT_MS - 3000;
      for (const timeout of [undefined, left * 10, MIN_SLICE_MS + 50]) call(ctx, name, timeout);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [left, left, left]);
    } finally { ctx.done(); }
  });

  test(`${name} armed after 3000 ms spent with the caller's shorter timeout: the child gets the time left, a timeout asks`, () => {
    const ctx = setup({ spentMs: 3000, behaviour: timedOut });
    try {
      const done = call(ctx, name, MIN_SLICE_MS + 50);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [ctx.limit.DECISION_TIME_LIMIT_MS - 3000]);
      assert.ifError(done.thrown);
      assert.deepStrictEqual([done.exited, done.code], [true, 0]);
      assert.strictEqual(fakes.writtenJson(ctx.fake).hookSpecificOutput.permissionDecision, "ask");
    } finally { ctx.done(); }
  });

  test(`${name} armed with exactly MIN_SLICE_MS left: the child starts with timeout MIN_SLICE_MS, no ask`, () => {
    const ctx = setup();
    try {
      ctx.fake.nowMs += ctx.limit.DECISION_TIME_LIMIT_MS - MIN_SLICE_MS;
      const done = call(ctx, name, undefined);
      assert.ifError(done.thrown);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [MIN_SLICE_MS]);
      assert.strictEqual(done.exited, false);
    } finally { ctx.done(); }
  });

  test(`${name} armed with the caller's timeout below MIN_SLICE_MS: the child starts with the time left, no ask`, () => {
    const ctx = setup();
    try {
      const done = call(ctx, name, 10);
      assert.ifError(done.thrown);
      assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [ctx.limit.DECISION_TIME_LIMIT_MS]);
      assert.strictEqual(done.exited, false);
      assert.deepStrictEqual(ctx.fake.written, []);
    } finally { ctx.done(); }
  });

  for (const timeout of [0, -1, NaN, Infinity]) {
    test(`${name} armed with the caller's timeout ${timeout}: the child timeout is the time left`, () => {
      const ctx = setup();
      try {
        const done = call(ctx, name, timeout);
        assert.ifError(done.thrown);
        assert.deepStrictEqual(ctx.calls.map((entry) => entry.timeout), [ctx.limit.DECISION_TIME_LIMIT_MS]);
        assert.strictEqual(done.exited, false);
      } finally { ctx.done(); }
    });
  }

  test(`${name} armed: a non-timeout error (ENOENT) goes back to the caller, no ask`, () => {
    const error = Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" });
    const result = { status: null, stdout: "", stderr: "", error };
    const ctx = setup({ behaviour: (fn) => { if (fn === "spawnSync") return result; throw error; } });
    try {
      const done = call(ctx, name, undefined);
      assert.strictEqual(done.exited, false, "no ask, the process goes on");
      assert.deepStrictEqual(ctx.fake.written, []);
      if (name === "spawnSync") {
        assert.ifError(done.thrown);
        assert.strictEqual(done.value.error.code, "ENOENT", "the result is returned as is");
      } else {
        assert.strictEqual(done.thrown, error, "the same error is thrown again");
      }
    } finally { ctx.done(); }
  });

  // The child returns after the time left ran out (stdio file I/O sits outside the child timeout).
  const enoent = () => Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" });
  const lateReturns = [
    ["a normal result", () => okResult("spawnSync")],
    ["a non-timeout error (ENOENT)", () => ({ status: null, stdout: "", stderr: "", error: enoent() })],
  ];
  if (name !== "spawnSync") lateReturns.push(["a non-zero exit (status 3)", () => ({ status: 3, stdout: "", stderr: "", error: undefined })]);
  // Armed calls reach the stub as spawnSync through file-stdio, so the stub answers a spawnSync result.
  const advancingBy = (spentInCall, answer) => {
    const holder = {};
    holder.ctx = setup({ behaviour: () => { holder.ctx.fake.nowMs += spentInCall(holder.ctx.limit); return answer(); } });
    return holder.ctx;
  };
  for (const [label, answer] of lateReturns) {
    test(`${name} armed: ${label} returned with no time left asks, the caller receives nothing`, () => {
      const ctx = advancingBy((limit) => limit.DECISION_TIME_LIMIT_MS, answer);
      try {
        const done = call(ctx, name, undefined);
        assert.strictEqual(ctx.calls.length, 1, "the child is started once");
        assert.ifError(done.thrown);
        assert.deepStrictEqual([done.exited, done.code, done.value], [true, 0, undefined]);
        // The fake exit throws, so the wrapper's catch may ask a second time; a real exit never returns.
        assert.strictEqual(JSON.parse(ctx.fake.written[0]).hookSpecificOutput.permissionDecision, "ask");
      } finally { ctx.done(); }
    });
  }

  test(`${name} armed: a normal result returned with 1 ms left does not ask, the result goes back`, () => {
    const ctx = advancingBy((limit) => limit.DECISION_TIME_LIMIT_MS - 1, () => okResult("spawnSync"));
    try {
      const done = call(ctx, name, undefined);
      assert.ifError(done.thrown);
      assert.strictEqual(done.exited, false, "no ask, the process goes on");
      assert.deepStrictEqual(ctx.fake.written, []);
      if (name === "spawnSync") assert.strictEqual(done.value.status, 0, "the result is returned");
      else assert.strictEqual(done.value.length, 0, "the empty stdout is returned");
    } finally { ctx.done(); }
  });
}

// TL2: a real child is always cut by the time left, whatever timeout the caller passed.
const DRIVER = path.join(__dirname, "feature-2676-limited-child-process", "driver.js");
const drive = (fnName, timeoutArg) => {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  return childProcess.spawnSync(process.execPath, [DRIVER, fnName, timeoutArg],
    { env, cwd: require("node:os").tmpdir(), encoding: "utf8", timeout: 60000 });
};
for (const name of FNS) {
  test(`TL2 ${name}: a real child cut by the time left -> ask on stdout, exit 0`, () => {
    const done = drive(name, "none");
    assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
    const out = JSON.parse(done.stdout.trim());
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
    assert.ok(out.hookSpecificOutput.permissionDecisionReason.startsWith("example-hook: decision time limit"));
  });
  test(`TL2 ${name}: a real child with the caller's shorter timeout is still cut by the time left -> ask, exit 0`, () => {
    const done = drive(name, "300");
    assert.strictEqual(done.status, 0, `driver exit (stderr: ${done.stderr})`);
    const out = JSON.parse(done.stdout.trim());
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
    assert.ok(out.hookSpecificOutput.permissionDecisionReason.startsWith("example-hook: decision time limit"));
  });
}

// TL2: armed children run with file-backed stdio, so a grandchild holding an inherited stdout
// cannot keep spawnSync from returning at the cap (#2676: a 2000 ms timeout once returned after 302 s).
const STDIO_DRIVER = path.join(__dirname, "feature-2676-limited-child-process", "stdio-driver.js");
const GRANDCHILD_BOUND_MS = require("../../hooks/lib/decision-time-limit").DECISION_TIME_LIMIT_MS + 3000;
const hasBash = (() => {
  try { return childProcess.spawnSync("bash", ["-c", "exit 0"], { stdio: "ignore", timeout: 10000 }).status === 0; } catch { return false; }
})();
// driveStdio(mode) -> { record, wallMs }: the driver runs with no pipe to this process.
const driveStdio = (mode) => {
  const fs = require("node:fs");
  const os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lcp-stdio-"));
  const out = path.join(dir, "record.json");
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  const startMs = Date.now();
  try {
    const done = childProcess.spawnSync(process.execPath, [STDIO_DRIVER, mode, out],
      { env, cwd: os.tmpdir(), stdio: "ignore", timeout: 90000 });
    const wallMs = Date.now() - startMs;
    assert.ok(fs.existsSync(out), `driver wrote no record (status ${done.status}, error ${done.error && done.error.code})`);
    const record = JSON.parse(fs.readFileSync(out, "utf8"));
    assert.strictEqual(record.driverError, undefined, record.driverError);
    return { record, wallMs, status: done.status };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
};
const resultOf = (record) => {
  assert.strictEqual(record.ask, undefined, `the time-left cap cut the child: ${record.ask}`);
  assert.strictEqual(record.thrown, undefined, `the driver threw: ${JSON.stringify(record.thrown)}`);
  return record.result;
};

test("TL2 spawnSync armed: a grandchild holding stdout does not delay the ask past the cap",
  { skip: hasBash ? false : "bash is not available" }, () => {
    const { record, wallMs } = driveStdio("grandchild");
    assert.strictEqual(record.exit, 0, `askAndExit reached (record: ${JSON.stringify(record)})`);
    assert.strictEqual(JSON.parse(record.ask.trim()).hookSpecificOutput.permissionDecision, "ask");
    assert.ok(record.elapsedMs < GRANDCHILD_BOUND_MS, `ask within ${GRANDCHILD_BOUND_MS} ms of the call, took ${record.elapsedMs} ms`);
    assert.ok(wallMs < GRANDCHILD_BOUND_MS + 5000, `driver ended promptly, took ${wallMs} ms`);
  });

test("TL2 spawnSync armed with input and utf8: stdout, stderr, output[1..2] and status as child_process gives them", () => {
  const result = resultOf(driveStdio("spawn-io").record);
  assert.strictEqual(result.error, null);
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stdout, "hello-in");
  assert.strictEqual(result.stderr, "err-text");
  assert.strictEqual(result.output1, "hello-in");
  assert.strictEqual(result.output2, "err-text");
});

test("TL2 execFileSync armed, non-zero exit: throws an Error carrying status, stdout and stderr", () => {
  const result = resultOf(driveStdio("execfile-fail").record);
  assert.strictEqual(result.threw, true, "execFileSync throws on exit 3");
  assert.strictEqual(result.isError, true);
  assert.strictEqual(result.status, 3);
  assert.strictEqual(result.stdout, "out-text");
  assert.strictEqual(result.stderr, "err-text");
});

test("TL2 execSync armed, success: stdout as a Buffer by default, as a string with encoding", () => {
  const result = resultOf(driveStdio("exec-ok").record);
  assert.deepStrictEqual(result.plain, { isBuffer: true, type: "object", text: "ok-text" });
  assert.deepStrictEqual(result.encoded, { isBuffer: false, type: "string", text: "ok-text" });
});

for (const name of FNS) {
  test(`TL2 ${name} armed, file-stdio setup fails: ask and exit 0 instead of a crash`, () => {
    const { record, status } = driveStdio(`setup-fail-${name}`);
    assert.strictEqual(record.thrown, undefined, `the setup error escaped: ${JSON.stringify(record.thrown)}`);
    assert.strictEqual(record.result, undefined, `the call returned instead of asking: ${JSON.stringify(record.result)}`);
    assert.deepStrictEqual([record.exit, status], [0, 0], "askAndExit ended the driver with 0");
    const out = JSON.parse(record.ask.trim());
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
    assert.ok(out.hookSpecificOutput.permissionDecisionReason.startsWith("example-hook: decision time limit"));
  });
}

test("TL2 spawnSync armed, stdin file written then its open fails: ask, and the file holding the input is already removed", () => {
  const { record, status } = driveStdio("setup-fail-after-input");
  assert.strictEqual(record.thrown, undefined, `the setup error escaped: ${JSON.stringify(record.thrown)}`);
  assert.strictEqual(record.inputWritten, true, `the stdin file held the input when its open failed: ${JSON.stringify(record)}`);
  assert.deepStrictEqual([record.exit, status], [0, 0], "askAndExit ended the driver with 0");
  assert.strictEqual(JSON.parse(record.ask.trim()).hookSpecificOutput.permissionDecision, "ask");
  assert.deepStrictEqual(record.atAsk, { holders: [] }, "no stdio file still holds the input when the hook asks");
});

test("TL2 spawnSync armed, caller stdio 'ignore' for stdout: result.stdout is null", () => {
  const result = resultOf(driveStdio("ignore-stdout").record);
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stdout, null);
  assert.strictEqual(result.output1, null);
  assert.strictEqual(result.stderr, "y");
});
