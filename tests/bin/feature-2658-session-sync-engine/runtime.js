"use strict";
// Runtime parts of tests/bin/feature-2658-session-sync-engine.js and -integrate-7.js (#2658): lock
// acquisition and stale recovery, deadline kill of the whole process tree (and, on win32, a timed-out
// run that resolves only after the tree is gone), and the pinned plan-sync dependency.
// Holds no case markers; each export registers the tests of one module.
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { pidAlive, sleep } = require("./fixtures");

const LOCK_NAME = "agents-session-sync.lock";

function lock(F) {
  const gitDirOf = (name) => {
    const dir = path.join(F.TMP, `lock-${name}`, ".git");
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  };
  test("lock.acquire refuses a second holder while the first is live, and frees on release", async () => {
    const L = F.lib("lock");
    const gitDir = gitDirOf("live");
    const first = await L.acquire(gitDir, { waitMs: 0 });
    assert.ok(first, "first acquire must succeed");
    assert.ok(fs.existsSync(path.join(gitDir, LOCK_NAME)), "lock file must be at .git/agents-session-sync.lock");
    assert.strictEqual(await L.acquire(gitDir, { waitMs: 0 }), null);
    await first.release();
    const again = await L.acquire(gitDir, { waitMs: 0 });
    assert.ok(again, "acquire after release must succeed");
    await again.release();
  });
  test("lock.acquire waits up to waitMs before giving up", async () => {
    const L = F.lib("lock");
    const gitDir = gitDirOf("wait");
    const held = await L.acquire(gitDir, { waitMs: 0 });
    const t0 = Date.now();
    assert.strictEqual(await L.acquire(gitDir, { waitMs: 1500 }), null);
    assert.ok(Date.now() - t0 >= 1000, `gave up after ${Date.now() - t0} ms`);
    await held.release();
  });
  test("lock.acquire takes over a lock older than 10 minutes whose holder is dead", async () => {
    const gitDir = gitDirOf("stale");
    const script = `Promise.resolve(require(${JSON.stringify(path.join(F.LIB, "lock.js"))}).acquire(${JSON.stringify(gitDir)}, { waitMs: 0 })).then(() => process.exit(0))`;
    const child = spawnSync(process.execPath, ["-e", script], { encoding: "utf8", timeout: 30000 });
    assert.strictEqual(child.status, 0, child.stderr);
    const file = path.join(gitDir, LOCK_NAME);
    assert.ok(fs.existsSync(file), "the exited holder must leave its lock behind");
    const old = new Date(Date.now() - 11 * 60 * 1000);
    fs.utimesSync(file, old, old);
    const taken = await F.lib("lock").acquire(gitDir, { waitMs: 0 });
    assert.ok(taken, "a stale lock must be recovered");
    await taken.release();
  });
}

function proc(F) {
  test("proc.run kills the child and its grandchild at the deadline", async () => {
    const dir = path.join(F.TMP, "proc-tree");
    fs.mkdirSync(dir, { recursive: true });
    const pids = path.join(dir, "pids.txt");
    const done = path.join(dir, "grandchild-done.txt");
    const grand = `setTimeout(() => require("fs").writeFileSync(${JSON.stringify(done)}, "x"), 3000)`;
    const childSrc = `const c = require("child_process").spawn(process.execPath, ["-e", ${JSON.stringify(grand)}], { stdio: "ignore", windowsHide: true });`
      + `require("fs").writeFileSync(${JSON.stringify(pids)}, process.pid + " " + c.pid); setTimeout(() => {}, 20000);`;
    const t0 = Date.now();
    const r = await F.lib("proc").run(process.execPath, ["-e", childSrc], { deadlineMs: 1500 });
    const elapsed = Date.now() - t0;
    assert.strictEqual(r.timedOut, true);
    assert.ok(elapsed < 8000, `run returned after ${elapsed} ms`);
    const [childPid, grandPid] = fs.readFileSync(pids, "utf8").trim().split(" ").map(Number);
    await sleep(3500);
    assert.strictEqual(pidAlive(childPid), false, `child ${childPid} still alive`);
    assert.strictEqual(pidAlive(grandPid), false, `grandchild ${grandPid} still alive`);
    assert.strictEqual(fs.existsSync(done), false, "the grandchild ran to completion");
  });
  test("proc.run reports the exit code of a process that finishes in time", async () => {
    const r = await F.lib("proc").run(process.execPath, ["-e", "process.exit(7)"], { deadlineMs: 20000 });
    assert.deepStrictEqual({ code: r.code, timedOut: r.timedOut }, { code: 7, timedOut: false });
  });
}

// treeSrc(pids) — a child that spawns a long-lived grandchild and records "<child> <grandchild>" in pids.
function treeSrc(pids) {
  const grand = "setTimeout(() => {}, 30000)";
  return `const c = require("child_process").spawn(process.execPath, ["-e", ${JSON.stringify(grand)}], { stdio: "ignore", windowsHide: true });`
    + `require("fs").writeFileSync(${JSON.stringify(pids)}, process.pid + " " + c.pid); setTimeout(() => {}, 30000);`;
}

const reap = (pid) => { try { process.kill(pid, "SIGKILL"); } catch (_) { /* already gone */ } };

function procKillWait(F) {
  const win = process.platform === "win32";
  test("proc.run resolves a timed-out run only after the grandchild is already gone (win32)", { skip: !win && "taskkill path is win32-only" }, async () => {
    const dir = path.join(F.TMP, "proc-kill-wait");
    fs.mkdirSync(dir, { recursive: true });
    const pids = path.join(dir, "pids.txt");
    const t0 = Date.now();
    const r = await F.lib("proc").run(process.execPath, ["-e", treeSrc(pids)], { deadlineMs: 2500 });
    const [childPid, grandPid] = fs.readFileSync(pids, "utf8").trim().split(" ").map(Number);
    const childAlive = pidAlive(childPid);
    const grandAlive = pidAlive(grandPid);
    const elapsed = Date.now() - t0;
    reap(grandPid);
    reap(childPid);
    assert.strictEqual(r.timedOut, true);
    assert.strictEqual(childAlive, false, `child ${childPid} still alive when run() resolved`);
    assert.strictEqual(grandAlive, false, `grandchild ${grandPid} still alive when run() resolved`);
    assert.ok(elapsed < 2500 + 6000, `run returned after ${elapsed} ms`);
  });
  test("proc.killTree neither throws nor rejects for a pid that no longer exists and settles within the cap", async () => {
    const gone = spawnSync(process.execPath, ["-e", "process.stdout.write(String(process.pid))"], { encoding: "utf8", timeout: 30000 });
    const pid = Number(gone.stdout);
    assert.ok(pid > 0, "the probe process reported its pid");
    const stub = { pid, kill() { throw new Error("ESRCH"); } };
    const r = await settledKill(F.lib("proc"), stub);
    assert.strictEqual(r.failed, null, `killTree threw or rejected: ${r.failed}`);
    assert.ok(r.elapsed < 6000, `killTree settled after ${r.elapsed} ms`);
  });
  test("proc.killTree of a live tree settles within the 5 s cap plus slack", async () => {
    const dir = path.join(F.TMP, "proc-kill-cap");
    fs.mkdirSync(dir, { recursive: true });
    const pids = path.join(dir, "pids.txt");
    const child = require("node:child_process").spawn(process.execPath, ["-e", treeSrc(pids)], { stdio: "ignore", windowsHide: true, detached: true });
    const until = Date.now() + 15000;
    while (!fs.existsSync(pids) && Date.now() < until) spawnSync(process.execPath, ["-e", "setTimeout(() => {}, 100)"]);
    assert.ok(fs.existsSync(pids), "the tree recorded its pids");
    const r = await settledKill(F.lib("proc"), child);
    for (const p of fs.readFileSync(pids, "utf8").trim().split(" ").map(Number)) reap(p);
    child.unref();
    assert.strictEqual(r.failed, null, `killTree threw or rejected: ${r.failed}`);
    assert.ok(r.elapsed < 6000, `killTree settled after ${r.elapsed} ms`);
  });
  for (const mode of ["slow", "pastCap", "enoent", "eperm"]) {
    test(`proc.killTree on win32 waits for a taskkill that ${STUB_LABEL[mode]}, within the 5 s cap, without throwing or rejecting`, async () => {
      const { result, calls } = await withStubbedTaskkill(F, mode, (proc) => settledKill(proc, { pid: 424242, kill() { throw new Error("ESRCH"); } }));
      assert.strictEqual(result.failed, null, `killTree threw or rejected: ${result.failed}`);
      assert.strictEqual(calls.length, 1, `taskkill must run once; calls: ${JSON.stringify(calls)}`);
      assert.deepStrictEqual(calls[0].args, ["/T", "/F", "/PID", "424242"]);
      assert.ok(result.elapsed < 6000, `killTree settled after ${result.elapsed} ms`);
      if (mode !== "enoent") assert.ok(result.elapsed >= 280, `killTree settled after ${result.elapsed} ms, before the ${STUB_DELAY} ms taskkill finished`);
      const t = calls[0].opts && calls[0].opts.timeout;
      if (calls[0].fn === "spawnSync" || t !== undefined) assert.ok(typeof t === "number" && t > 0 && t <= 5000, `taskkill timeout must be in (0, 5000], got ${t}`);
    });
  }
}

// settledKill(proc, child) -> {failed, elapsed}: elapsed runs until Promise.resolve(killTree(child)) settles.
async function settledKill(proc, child) {
  const t0 = Date.now();
  let failed = null;
  let guard;
  const limit = new Promise((resolve) => { guard = setTimeout(() => resolve("killTree did not settle in 8000 ms"), 8000); });
  try {
    failed = await Promise.race([Promise.resolve(proc.killTree(child)).then(() => null), limit]);
  } catch (e) {
    failed = e;
  } finally {
    clearTimeout(guard);
  }
  return { failed, elapsed: Date.now() - t0 };
}

const STUB_DELAY = 300;
const STUB_LABEL = {
  slow: "takes 300 ms", pastCap: "runs past the 5 s cap", enoent: "is missing (ENOENT)", eperm: "fails with EPERM after 300 ms",
};
const errOf = (code) => Object.assign(new Error(`taskkill ${code}`), { code });
const capped = (opts) => Boolean(opts) && typeof opts.timeout === "number" && opts.timeout > 0 && opts.timeout <= 5000;
const block = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// fakeTaskkillSync(mode, opts) — the spawnSync result after blocking like a real taskkill would.
// pastCap without a capped timeout blocks 6500 ms, so an uncapped wait fails the elapsed check.
function fakeTaskkillSync(mode, opts) {
  if (mode === "enoent") throw errOf("ENOENT");
  if (mode === "pastCap" && !capped(opts)) block(6500);
  else block(STUB_DELAY);
  const base = { pid: 0, output: [null, "", ""], stdout: "", stderr: "" };
  if (mode === "slow") return { ...base, status: 0, signal: null };
  if (mode === "eperm") return { ...base, status: 1, signal: null, error: errOf("EPERM") };
  return { ...base, status: null, signal: "SIGTERM", error: errOf("ETIMEDOUT") };
}

// fakeTaskkill(mode, opts) — a ChildProcess-like emitter; pastCap without a capped timeout never exits,
// so only an implementation that caps its own wait settles.
function fakeTaskkill(mode, opts) {
  if (mode === "enoent") throw errOf("ENOENT");
  const { EventEmitter } = require("node:events");
  const c = Object.assign(new EventEmitter(), { pid: 0, stdout: null, stderr: null, unref() {}, ref() {}, kill() { return true; } });
  if (mode === "pastCap" && !capped(opts)) return c;
  setTimeout(() => {
    if (mode === "eperm" && c.listenerCount("error") > 0) c.emit("error", errOf("EPERM"));
    const code = mode === "slow" ? 0 : (mode === "eperm" ? 1 : null);
    const sig = mode === "pastCap" ? "SIGTERM" : null;
    c.emit("exit", code, sig);
    c.emit("close", code, sig);
  }, STUB_DELAY);
  return c;
}

// withStubbedTaskkill(F, mode, fn) — process.platform reads win32 and child_process spawn/spawnSync of
// "taskkill" are faked per mode while await fn(freshProc) runs on a proc.js required anew; every stub
// and the require cache entry are restored afterward.
async function withStubbedTaskkill(F, mode, fn) {
  const cp = require("node:child_process");
  const procPath = require.resolve(path.join(F.LIB, "proc.js"));
  const real = { spawn: cp.spawn, spawnSync: cp.spawnSync, platform: Object.getOwnPropertyDescriptor(process, "platform") };
  const calls = [];
  const isTaskkill = (cmd) => /(^|[\\/])taskkill(\.exe)?$/i.test(String(cmd));
  cp.spawnSync = function (cmd, args, opts) {
    if (!isTaskkill(cmd)) return real.spawnSync.apply(cp, arguments);
    calls.push({ fn: "spawnSync", args, opts });
    return fakeTaskkillSync(mode, opts);
  };
  cp.spawn = function (cmd, args, opts) {
    if (!isTaskkill(cmd)) return real.spawn.apply(cp, arguments);
    calls.push({ fn: "spawn", args, opts });
    return fakeTaskkill(mode, opts);
  };
  Object.defineProperty(process, "platform", { value: "win32", configurable: true });
  delete require.cache[procPath];
  try {
    return { result: await fn(require(procPath)), calls };
  } finally {
    Object.defineProperty(process, "platform", real.platform);
    cp.spawn = real.spawn;
    cp.spawnSync = real.spawnSync;
    delete require.cache[procPath];
  }
}

function gitDep(F) {
  test("git.js reuses the four plan-sync git helpers and nothing else from plan-sync", () => {
    const src = fs.readFileSync(path.join(F.LIB, "git.js"), "utf8");
    assert.ok(/require\([^)]*plan-sync[\\/]+git(\.js)?["']\)/.test(src), "git.js must require hooks/lib/plan-sync/git.js");
    const ps = require(path.join(F.REPO, "hooks", "lib", "plan-sync", "git.js"));
    for (const name of ["runGit", "buildEnv", "casUpdate", "isNonFastForward"]) {
      assert.strictEqual(typeof ps[name], "function", `plan-sync git.js must export ${name}`);
    }
    const destructured = src.match(/\{([^}]*)\}\s*=\s*require\([^)]*plan-sync/);
    if (destructured) {
      const used = destructured[1].split(",").map((s) => s.trim().split(":")[0].trim()).filter(Boolean);
      for (const u of used) assert.ok(["runGit", "buildEnv", "casUpdate", "isNonFastForward"].includes(u), `unexpected plan-sync import ${u}`);
    }
  });
}

module.exports = { lock, proc, procKillWait, gitDep };
