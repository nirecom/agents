"use strict";
// Runtime parts of tests/bin/feature-2658-session-sync-engine.js (#2658): lock acquisition and
// stale recovery, deadline kill of the whole process tree, and the pinned plan-sync dependency.
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

module.exports = { lock, proc, gitDep };
