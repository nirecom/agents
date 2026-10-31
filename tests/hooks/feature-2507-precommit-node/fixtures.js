"use strict";
// Shared fixtures of tests/hooks/feature-2507-precommit-node.js (#2507). Holds no case markers.
// Every pre-commit.d module is loaded fresh inside a test, so a missing module fails that test
// alone; external modules (session markers, exclude-check, gate checkers) resolve from cfgDir.
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..", "..");
const PCD = path.join(REPO, "hooks", "pre-commit.d");
const GIT_ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX"];

function cleanEnv(extra = {}) {
  const env = { ...process.env };
  for (const k of GIT_ENV_DROP) delete env[k];
  return { ...env, ...extra };
}

function makeFixtures(tmpRoot, gitInit) {
  let seq = 0;
  const tmp = (name) => {
    seq += 1;
    const dir = path.join(tmpRoot, `${name}-${seq}`);
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  };
  const git = (cwd, args, { allowFail = false, env } = {}) => {
    const done = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: env || cleanEnv() });
    if (!allowFail) assert.strictEqual(done.status, 0, `git ${args.join(" ")}: ${done.stderr}`);
    return allowFail ? done : done.stdout.trim();
  };
  const write = (dir, rel, body, mode) => {
    const file = path.join(dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
    if (mode !== undefined) fs.chmodSync(file, mode);
    return file;
  };
  // repo(name, { branch, seed }) — a fixture repo on <branch>; seed false leaves HEAD unborn.
  const repo = (name, { branch = "main", seed = true } = {}) => {
    const dir = tmp(name);
    gitInit(dir);
    git(dir, ["config", "user.name", "f2507"]);
    git(dir, ["config", "user.email", "f2507@example.invalid"]);
    git(dir, ["config", "commit.gpgsign", "false"]);
    git(dir, ["symbolic-ref", "HEAD", `refs/heads/${branch}`]);
    if (seed) {
      write(dir, "seed.txt", "seed\n");
      git(dir, ["add", "seed.txt"]);
      git(dir, ["commit", "-q", "-m", "seed"]);
    }
    return dir;
  };
  const stage = (dir, ...rels) => git(dir, ["add", "--", ...rels]);
  // runCheck(name, opts) — checks/<name>.js run over a real snapshot of opts.repoTop.
  const runCheck = async (name, { repoTop, cfgDir, env, isTTY = false, isAgentsRepo = true, visibility }) => {
    const snapshot = await fresh("snapshot.js").createSnapshot({ repoTop, env });
    const context = { repoTop, cfgDir, env, isTTY, isAgentsRepo, merge: { state: "not-merging" }, visibility: visibility || { kill() {} } };
    const files = await snapshot.files();
    return fresh(`checks/${name}.js`).run({ context, snapshot, files });
  };
  // runEntry(name, opts) — the shipped registry entry <name> alone through orchestrator.run, with
  // the real checks/<name>.js; resolves to { value: rc, log } with the captured writes.
  const runEntry = async (name, { repoTop, cfgDir, env, isTTY = false, isAgentsRepo = true }) => {
    const entry = fresh("registry.js").CHECKS.find((c) => c.name === name);
    const snapshot = await fresh("snapshot.js").createSnapshot({ repoTop, env });
    const context = { repoTop, cfgDir, env, isTTY, isAgentsRepo, merge: { state: "not-merging" }, visibility: { kill() {} } };
    const orch = fresh("orchestrator.js");
    const check = require(path.join(PCD, "checks", `${name}.js`));
    return capture(() => orch.run({ entries: [entry], context, snapshot, loadCheck: () => check }));
  };
  return { REPO, PCD, tmp, git, write, repo, stage, runCheck, runEntry, cleanEnv, envWith, fresh, capture, texts, messageOf, posixDrive };
}

// envWith(over) — cleanEnv() with each key of over set, or removed when its value is undefined.
function envWith(over) {
  const env = cleanEnv();
  for (const [k, v] of Object.entries(over)) {
    if (v === undefined) delete env[k];
    else env[k] = v;
  }
  return env;
}

// fresh(rel) — the pre-commit.d module at <rel>, loaded after dropping every cached pre-commit.d
// module, so a fs.writeSync patch installed before the call is the one the module sees.
function fresh(rel) {
  for (const key of Object.keys(require.cache)) if (key.startsWith(PCD)) delete require.cache[key];
  return require(path.join(PCD, rel));
}

// capture(fn) — runs fn(log) with fs.writeSync on fd 1/2 recorded into log as {fd, text}; a stub
// may push its own {event} rows into the same log, so the order of writes and calls is visible.
async function capture(fn) {
  const real = fs.writeSync;
  const log = [];
  fs.writeSync = function patched(fd, data, ...rest) {
    if (fd === 1 || fd === 2) {
      const text = Buffer.isBuffer(data) ? data.toString("utf8") : String(data);
      log.push({ fd, text });
      return Buffer.byteLength(text);
    }
    return real.call(fs, fd, data, ...rest);
  };
  try {
    const value = await fn(log);
    return { value, log };
  } finally {
    fs.writeSync = real;
  }
}

const texts = (result) => (result && Array.isArray(result.messages) ? result.messages.map((m) => m.text).join("\n") : "");
const messageOf = (result, needle) => (result.messages || []).find((m) => String(m.text).includes(needle));

// posixDrive(p) — the Git Bash spelling (/c/...) of a Windows path; unchanged elsewhere.
function posixDrive(p) {
  if (process.platform !== "win32") return p;
  return p.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_m, d) => `/${d.toLowerCase()}`);
}

module.exports = { makeFixtures, cleanEnv, REPO, PCD };
