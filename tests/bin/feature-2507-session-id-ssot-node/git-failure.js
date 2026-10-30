"use strict";
// Tests: bin/check-session-id-ssot/main.js
// Tags: TL1, bin, session-id, fail-closed, scope:issue-specific
// `git ls-files` failure checks of tests/bin/feature-2507-session-id-ssot-node.js (#2507). Holds no
// case markers. A no-path run that cannot list the tree must end rc 2, never judge "0 files" clean.
const assert = require("node:assert");
const cp = require("node:child_process");
const path = require("node:path");
const F = require("./fixture");

const ROWS = [{ path: "hooks/g.js", lines: ["const sid = process.env.SESSION_ID;"], want: [1] }];

function runEnv(extra = {}) {
  const env = { ...process.env, LC_ALL: "C.UTF-8", ...extra };
  for (const k of ["CLAUDE_CODE_SESSION_ID", F.RET_S, F.RET_E, "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]) delete env[k];
  return env;
}

async function runMain(cwd, env) {
  let stdout = "";
  let stderr = "";
  const rc = await require(F.MAIN).run({
    argv: [], cwd, env,
    stdout: { write: (s) => { stdout += String(s); return true; } },
    stderr: { write: (s) => { stderr += String(s); return true; } },
  });
  return { rc, stdout, stderr };
}

function assertSetupFailure(got, label) {
  assert.strictEqual(got.rc, 2, `${label}: rc (stdout ${JSON.stringify(got.stdout)}, stderr ${JSON.stringify(got.stderr)})`);
  assert.ok(/check-session-id-ssot: \S/.test(got.stderr), `${label}: stderr diagnostic ${JSON.stringify(got.stderr)}`);
  assert.strictEqual(got.stdout, "", `${label}: stdout`);
}

// A tree outside any repository: `git ls-files` exits 128.
async function lsFilesNonZero() {
  const tree = F.makeTree("nogit", ROWS);
  const got = await runMain(tree, runEnv({ GIT_CEILING_DIRECTORIES: path.dirname(tree) }));
  assertSetupFailure(got, "git ls-files rc 128");
}

// A spawn error other than ENOENT (maxBuffer, timeout), injected through the child_process module
// object that limited-child-process calls at call time; the partial stdout must not be judged.
async function lsFilesSpawnError() {
  const tree = F.makeTree("spawnerr", ROWS);
  for (const code of ["ENOBUFS", "ETIMEDOUT"]) {
    const real = cp.spawnSync;
    cp.spawnSync = function patched(command, args, ...rest) {
      if (Array.isArray(args) && args[0] === "ls-files") {
        const error = Object.assign(new Error(`spawnSync git ${code}`), { code });
        return { error, status: null, signal: null, stdout: "hooks/g.js\0hooks/par", stderr: "" };
      }
      return real.call(this, command, args, ...rest);
    };
    try {
      assertSetupFailure(await runMain(tree, runEnv()), `spawn error ${code}`);
    } finally {
      cp.spawnSync = real;
    }
  }
}

// `git ls-files` killed by a signal: status null, signal set, no error, so the empty stdout must not
// be judged as a clean "0 files" tree.
async function lsFilesSignal() {
  const tree = F.makeTree("signal", ROWS);
  const real = cp.spawnSync;
  cp.spawnSync = function patched(command, args, ...rest) {
    if (Array.isArray(args) && args[0] === "ls-files") return { status: null, signal: "SIGKILL", stdout: "", stderr: "" };
    return real.call(this, command, args, ...rest);
  };
  try {
    assertSetupFailure(await runMain(tree, runEnv()), "git ls-files killed by SIGKILL");
  } finally {
    cp.spawnSync = real;
  }
}

// git missing from PATH: spawnSync reports ENOENT with no stdout; that is a setup failure too.
async function lsFilesEnoent() {
  const tree = F.makeTree("enoent", ROWS);
  const real = cp.spawnSync;
  cp.spawnSync = function patched(command, args, ...rest) {
    if (Array.isArray(args) && args[0] === "ls-files") {
      const error = Object.assign(new Error("spawnSync git ENOENT"), { code: "ENOENT", errno: -2, syscall: "spawnSync git", path: "git" });
      return { error, status: null, signal: null, stdout: null, stderr: null };
    }
    return real.call(this, command, args, ...rest);
  };
  try {
    const got = await runMain(tree, runEnv());
    assertSetupFailure(got, "git not found (ENOENT)");
    assert.ok(/check-session-id-ssot: .*git/.test(got.stderr), `ENOENT diagnostic names git: ${JSON.stringify(got.stderr)}`);
  } finally {
    cp.spawnSync = real;
  }
}

module.exports = { lsFilesNonZero, lsFilesSpawnError, lsFilesSignal, lsFilesEnoent };
