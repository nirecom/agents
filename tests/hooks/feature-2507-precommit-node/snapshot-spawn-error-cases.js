"use strict";
// Tests: hooks/pre-commit.d/snapshot.js
// Tags: TL1, pre-commit, snapshot, cat-file, fail-closed, scope:issue-specific
// cat-file start-failure part of tests/hooks/feature-2507-precommit-node.js (#2507). Holds no case
// markers. A `git cat-file --batch` that never ran cleanly (spawn error, timeout, maxBuffer) leaves
// r.error set; the snapshot must throw on it, and the orchestrator must block the commit, the same
// way the `git ls-files` start failures fail closed in the session-id guard.
const assert = require("node:assert");
const cp = require("node:child_process");
const { test } = require("node:test");

const CODES = ["ENOENT", "ETIMEDOUT", "ENOBUFS"];

// withCatFileError(code, fn) — fn() with every `git cat-file` start failing with code. ETIMEDOUT and
// ENOBUFS keep status 0 and the whole reply, so only the r.error check can refuse them.
async function withCatFileError(code, fn) {
  const real = cp.spawnSync;
  let calls = 0;
  cp.spawnSync = function patched(command, args, ...rest) {
    if (!(Array.isArray(args) && args[0] === "cat-file")) return real.call(this, command, args, ...rest);
    calls += 1;
    const r = real.call(this, command, args, ...rest);
    const error = Object.assign(new Error(`spawnSync git ${code}`), { code });
    if (code === "ENOENT") return { error, status: null, signal: null, stdout: null, stderr: null };
    return { ...r, error };
  };
  try {
    await fn();
  } finally {
    cp.spawnSync = real;
  }
  return calls;
}

function catFileSpawnError(F) {
  const modified = (name) => {
    const dir = F.repo(name);
    F.write(dir, "old.txt", "head side\n");
    F.stage(dir, "old.txt");
    F.git(dir, ["commit", "-q", "-m", "head side"]);
    F.write(dir, "old.txt", "staged side\n");
    F.stage(dir, "old.txt");
    return dir;
  };
  test("a cat-file spawn error (ENOENT, ETIMEDOUT, ENOBUFS) makes content() and headContent() throw", async () => {
    const dir = modified("snap-spawn-error");
    const control = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.strictEqual(Buffer.from(await control.content("old.txt")).toString("utf8"), "staged side\n", "control reads the blob");
    for (const code of CODES) {
      for (const side of ["content", "headContent"]) {
        const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
        const calls = await withCatFileError(code, () => assert.rejects(async () => snap[side]("old.txt"), `${side}() after ${code} must fail closed`));
        assert.strictEqual(calls, 1, `${code}/${side}: the patched cat-file was reached`);
      }
    }
  });
  test("a cat-file spawn error blocks the commit through the orchestrator (outbound-scan)", async () => {
    const dir = F.repo("scan-spawn-error");
    F.write(dir, "plain.txt", "alpha beta gamma\n");
    F.stage(dir, "plain.txt");
    const opts = { repoTop: dir, cfgDir: F.REPO, env: F.cleanEnv() };
    const control = await F.runEntry("outbound-scan", opts);
    assert.strictEqual(control.value, 0, "control: the intact read passes");
    for (const code of ["ENOENT", "ETIMEDOUT"]) {
      let got;
      await withCatFileError(code, async () => {
        got = await F.runEntry("outbound-scan", opts);
      });
      const stderr = got.log.filter((l) => l.fd === 2).map((l) => l.text).join("");
      assert.strictEqual(got.value, 1, `${code}: the commit must be blocked, got rc ${got.value}`);
      assert.ok(/pre-commit: outbound-scan failed \(.*\)\. Commit blocked/.test(stderr), `${code}: closed-mode wording ${JSON.stringify(stderr)}`);
    }
  });
}

module.exports = { catFileSpawnError };
