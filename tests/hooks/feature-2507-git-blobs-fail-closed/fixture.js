"use strict";
// Tests: hooks/lib/test-gates/git-blobs.js
// Tags: TL2, hooks, test-gates, git-blobs, cat-file, real-git, fail-closed, scope:issue-specific
// Fixtures of tests/hooks/feature-2507-git-blobs-fail-closed.js (#2507). Holds no case markers.
// withCatFile patches child_process.spawnSync through the module object: git-blobs.js requires it
// at call time, so the patch reaches every `git cat-file --batch` it starts.
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..", "..");
const GB = path.join(REPO, "hooks", "lib", "test-gates", "git-blobs.js");
const CLI = path.join(REPO, "bin", "check-test-frontmatter", "cli.js");
const GIT_ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES"];

function cleanEnv() {
  const env = { ...process.env };
  for (const k of GIT_ENV_DROP) delete env[k];
  return env;
}

// parseBatch(buf) -> [{ header, body }] of an intact reply; body is null for "<name> missing".
function parseBatch(buf) {
  const objs = [];
  let pos = 0;
  while (pos < buf.length) {
    const nl = buf.indexOf(0x0a, pos);
    assert.ok(nl >= 0, "control reply has a header LF");
    const header = buf.subarray(pos, nl).toString("utf8");
    if (header.endsWith(" missing")) {
      objs.push({ header, body: null });
      pos = nl + 1;
      continue;
    }
    const size = Number(header.split(" ")[2]);
    objs.push({ header, body: buf.subarray(nl + 1, nl + 1 + size) });
    pos = nl + 1 + size + 1;
  }
  return objs;
}

// buildBatch(objs) — the bytes parseBatch read; a row may set end ("" drops the LF after a body).
function buildBatch(objs) {
  const parts = [];
  for (const o of objs) {
    parts.push(Buffer.from(`${o.header}\n`));
    if (o.body !== null) parts.push(Buffer.from(o.body), Buffer.from(o.end === undefined ? "\n" : o.end));
  }
  return Buffer.concat(parts);
}

// withCatFile(edit, fn) — fn() with each cat-file result replaced by edit(result, input); calls
// records { args, input } of every cat-file start.
function withCatFile(edit, fn) {
  const real = cp.spawnSync;
  const calls = [];
  cp.spawnSync = function patched(command, args, ...rest) {
    const isCatFile = Array.isArray(args) && args[0] === "cat-file";
    const input = isCatFile && rest[0] ? String(rest[0].input) : "";
    if (isCatFile) calls.push({ args, input });
    const r = real.call(this, command, args, ...rest);
    if (!isCatFile) return r;
    try {
      return edit({ ...r, stdout: Buffer.from(r.stdout || "") }, input);
    } catch (e) {
      // A broken row is a test bug; tag it so a fail-closed row never counts it as a throw.
      throw Object.assign(e, { fromEdit: true });
    }
  };
  try {
    return { value: fn(), calls };
  } finally {
    cp.spawnSync = real;
  }
}

const fresh = (file) => {
  delete require.cache[require.resolve(file)];
  return require(file);
};

function makeFixtures(tmpRoot, gitInit) {
  let seq = 0;
  const git = (cwd, args) => {
    const done = cp.spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8", env: cleanEnv() });
    assert.strictEqual(done.status, 0, `git ${args.join(" ")}: ${done.stderr}`);
    return done.stdout.trim();
  };
  const write = (dir, rel, body) => {
    const file = path.join(dir, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
  };
  // repo(name, head, staged) — head files committed, then staged files written and added.
  const repo = (name, head = {}, staged = {}) => {
    seq += 1;
    const dir = path.join(tmpRoot, `${name}-${seq}`);
    fs.mkdirSync(dir, { recursive: true });
    gitInit(dir);
    git(dir, ["config", "user.name", "f2507"]);
    git(dir, ["config", "user.email", "f2507@example.invalid"]);
    git(dir, ["config", "commit.gpgsign", "false"]);
    write(dir, "seed.txt", "seed\n");
    for (const [n, b] of Object.entries(head)) write(dir, n, b);
    git(dir, ["add", "--", "seed.txt", ...Object.keys(head)]);
    git(dir, ["commit", "-q", "-m", "head"]);
    for (const [n, b] of Object.entries(staged)) write(dir, n, b);
    if (Object.keys(staged).length) git(dir, ["add", "--", ...Object.keys(staged)]);
    return dir;
  };
  const blobs = (dir, names) => fresh(GB).blobs(dir, cleanEnv(), names);
  // runCli(dir, argv) -> { rc, stderr } of check-test-frontmatter run() in dir.
  const runCli = (dir, argv) => {
    let stderr = "";
    const rc = fresh(CLI).run({ argv, cwd: dir, env: cleanEnv(), stderr: { write: (s) => { stderr += String(s); return true; } } });
    return { rc, stderr };
  };
  return { git, write, repo, blobs, runCli };
}

// spawnError(code, stdout) — a spawnSync result of a start that failed with code.
const spawnError = (code, stdout = null) => ({
  error: Object.assign(new Error(`spawnSync git ${code}`), { code }),
  status: null,
  signal: code === "ETIMEDOUT" ? "SIGTERM" : null,
  stdout,
  stderr: null,
});

const str = (b) => (b === undefined || b === null ? b : Buffer.from(b).toString("utf8"));

module.exports = { makeFixtures, withCatFile, parseBatch, buildBatch, spawnError, str };
