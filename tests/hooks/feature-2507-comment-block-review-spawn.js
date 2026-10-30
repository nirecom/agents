"use strict";
// Tests: hooks/lib/comment-block-review/review.js
// Tags: TL2, comment-block-size, pre-commit, spawn-count, real-git, scope:issue-specific
// #2507: the staged comment-block review started about four git processes per staged code file
// (size, staged blob, baseline lookup, baseline blob), so a large commit paid one Windows process
// start per call. The review must read every staged file with a fixed number of git processes —
// the count for 1 file equals the count for 20 — and its report must stay exactly what it is now.
// The real CLI runs in a child Node process whose child_process calls tests/lib/node-spawn-log.js
// records.
const { isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const CLI = path.join(REPO, "bin", "review-comment-block-size.d", "cli.js");
// NODE_OPTIONS reads a backslash as an escape, so the preload path is spelled with "/".
const SPAWN_LOG_JS = path.join(REPO, "tests", "lib", "node-spawn-log.js").replace(/\\/g, "/");
const GIT_ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "NODE_OPTIONS", "CLAUDE_CODE_SESSION_ID"];

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-cb-spawn-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

let seq = 0;
function tmpDir(name) {
  seq += 1;
  const dir = path.join(TMP, `${name}-${seq}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function baseEnv(extra = {}) {
  const env = { ...process.env };
  for (const k of GIT_ENV_DROP) delete env[k];
  return { ...env, ...extra };
}

function git(dir, ...args) {
  const r = spawnSync("git", ["-C", dir, ...args], { encoding: "utf8", env: baseEnv() });
  assert.strictEqual(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
}

function write(dir, rel, body) {
  const file = path.join(dir, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
}

function newRepo(name) {
  const dir = tmpDir(name);
  gitInit(dir);
  git(dir, "config", "user.name", "f2507");
  git(dir, "config", "user.email", "f2507@example.invalid");
  git(dir, "config", "commit.gpgsign", "false");
  git(dir, "config", "core.autocrlf", "false");
  return dir;
}

const comments = (n) => Array.from({ length: n }, (_, i) => `// note ${i + 1}`).join("\n");

// A cfgDir whose .env sets the threshold to 3 comment lines; the CLI finds it through AGENTS_MAIN_ROOT.
function cfgDir() {
  const dir = tmpDir("cfg");
  write(dir, ".env", "COMMENT_BLOCK_MAX_LINES=3\n");
  return dir;
}

// runCli(repo) -> { rc, stdout, stderr, records } with records the child's spawn log rows.
function runCli(repo) {
  const log = path.join(tmpDir("log"), "spawn.log");
  const r = spawnSync(process.execPath, [CLI, "--staged"], {
    cwd: repo,
    encoding: "utf8",
    timeout: 120000,
    env: baseEnv({ AGENTS_MAIN_ROOT: cfgDir(), NODE_OPTIONS: `--require "${SPAWN_LOG_JS}"`, TEST_NODE_SPAWN_LOG: log }),
  });
  assert.strictEqual(r.error, undefined, `spawn error ${r.error}`);
  let text = "";
  try {
    text = fs.readFileSync(log, "utf8");
  } catch {
    // A missing log leaves records empty; the main-record assertion fails on it.
  }
  const records = text.split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return { rc: r.status, stdout: r.stdout, stderr: r.stderr, records };
}

const line = (rec) => [rec.cmd, ...rec.args].join(" ").replace(/\\/g, "/");
const GIT_RE = /(^|\/)git(\.exe)?( |$)/;
function gitSpawns(res) {
  assert.ok(res.records.some((rec) => rec.fn === "main" && /review-comment-block-size\.d\/cli\.js/.test(line(rec))), "the CLI's own main record is logged (the preload reached it)");
  return res.records.filter((rec) => rec.fn !== "main" && GIT_RE.test(line(rec))).length;
}

// n tracked .js files, each staged with one more code line; none grows a comment run.
function modifiedRepo(n) {
  const dir = newRepo(`mod${n}`);
  for (let i = 0; i < n; i++) write(dir, `src/m${i}.js`, `${comments(2)}\nmodule.exports = ${i};\n`);
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "base");
  for (let i = 0; i < n; i++) write(dir, `src/m${i}.js`, `${comments(2)}\nmodule.exports = ${i};\nexports.more = ${i};\n`);
  git(dir, "add", "-A");
  return dir;
}

const runs = new Map();
function modifiedRun(n) {
  if (!runs.has(n)) runs.set(n, runCli(modifiedRepo(n)));
  return runs.get(n);
}

test("1 the fixture runs scan every staged file and pass (rc 0, scanned N)", () => {
  for (const n of [1, 5, 20]) {
    const r = modifiedRun(n);
    assert.strictEqual(r.rc, 0, `N=${n}: rc 0\n${r.stdout}${r.stderr}`);
    assert.ok(r.stdout.includes(`Staged code files scanned: ${n} (`), `N=${n}: scanned ${n}\n${r.stdout}`);
    assert.ok(gitSpawns(r) > 0, `N=${n}: git processes are logged`);
  }
});

test("2 the number of git processes does not grow with the staged file count (N=1, 5, 20)", () => {
  const counts = [1, 5, 20].map((n) => gitSpawns(modifiedRun(n)));
  assert.strictEqual(counts[1], counts[0], `N=5 starts ${counts[1]} git processes, N=1 starts ${counts[0]}`);
  assert.strictEqual(counts[2], counts[0], `N=20 starts ${counts[2]} git processes, N=1 starts ${counts[0]}`);
});

// Mixed staged set: new over-threshold, grown, unchanged over-threshold, small new, too large,
// renamed, and a non-code file. The report is today's, line for line.
function mixedRepo() {
  const dir = newRepo("mixed");
  write(dir, "grown.js", `${comments(4)}\nmodule.exports = 1;\n`);
  write(dir, "same.js", `${comments(5)}\nmodule.exports = 2;\n`);
  write(dir, "old.js", `${comments(5)}\nmodule.exports = 3;\nexports.a = 1;\nexports.b = 2;\n`);
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "base");
  write(dir, "grown.js", `${comments(6)}\nmodule.exports = 1;\n`);
  write(dir, "same.js", `${comments(5)}\nmodule.exports = 2;\nexports.more = 2;\n`);
  write(dir, "new.js", `${comments(5)}\nmodule.exports = 4;\n`);
  write(dir, "small.js", `${comments(2)}\nmodule.exports = 5;\n`);
  write(dir, "big.js", "module.exports = 6;\n".repeat(60000));
  write(dir, "notes.txt", `${comments(9)}\n`);
  git(dir, "mv", "old.js", "moved.js");
  git(dir, "add", "-A");
  return dir;
}

test("3 a mixed staged set keeps today's report and rc 1", () => {
  const r = runCli(mixedRepo());
  assert.strictEqual(r.rc, 1, `${r.stdout}${r.stderr}`);
  assert.deepStrictEqual(r.stdout.split("\n"), [
    "## Comment-block Size Review: PERFORMED (staged mode)",
    "Staged code files scanned: 5 (extensions: js;sh;py; threshold: > 3 comment lines per block)",
    "  skipped (too large): 1",
    "BLOCK: grown.js — longest comment run 4 → 6 lines (over-threshold runs 1 → 1)",
    "  L1-L6 (6 comment lines)",
    "BLOCK: new.js — longest comment run 5 lines (no baseline: absolute-state fallback)",
    "  L1-L5 (5 comment lines)",
    "  Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT).",
    "",
  ]);
});

// n of each kind: a file grown past its baseline (g<i>.js), a new over-threshold file (n<i>.js) and
// a renamed file without growth (r<i>.js, from o<i>.js). Every kind takes a different lookup path.
function scaledMixedRepo(n) {
  const dir = newRepo(`smix${n}`);
  for (let i = 0; i < n; i++) {
    write(dir, `g${i}.js`, `${comments(4)}\nmodule.exports = ${i};\n`);
    write(dir, `o${i}.js`, `${comments(5)}\nmodule.exports = ${i};\nexports.a = ${i};\nexports.b = ${i};\n`);
  }
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "base");
  for (let i = 0; i < n; i++) {
    write(dir, `g${i}.js`, `${comments(6)}\nmodule.exports = ${i};\n`);
    write(dir, `n${i}.js`, `${comments(5)}\nmodule.exports = ${i};\n`);
    git(dir, "mv", `o${i}.js`, `r${i}.js`);
  }
  git(dir, "add", "-A");
  return dir;
}

function scaledMixedReport(n) {
  const idx = Array.from({ length: n }, (_, i) => i);
  return [
    "## Comment-block Size Review: PERFORMED (staged mode)",
    `Staged code files scanned: ${3 * n} (extensions: js;sh;py; threshold: > 3 comment lines per block)`,
    ...idx.flatMap((i) => [`BLOCK: g${i}.js — longest comment run 4 → 6 lines (over-threshold runs 1 → 1)`, "  L1-L6 (6 comment lines)"]),
    ...idx.flatMap((i) => [`BLOCK: n${i}.js — longest comment run 5 lines (no baseline: absolute-state fallback)`, "  L1-L5 (5 comment lines)"]),
    "  Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT).",
    "",
  ];
}

const mixedRuns = new Map();
function scaledMixedRun(n) {
  if (!mixedRuns.has(n)) mixedRuns.set(n, runCli(scaledMixedRepo(n)));
  return mixedRuns.get(n);
}

test("4 a scaled mixed set (grown, new, renamed) keeps today's report for N=1 and N=4", () => {
  for (const n of [1, 4]) {
    const r = scaledMixedRun(n);
    assert.strictEqual(r.rc, 1, `N=${n}: rc 1\n${r.stdout}${r.stderr}`);
    assert.deepStrictEqual(r.stdout.split("\n"), scaledMixedReport(n), `N=${n}`);
  }
});

test("5 on the scaled mixed set the git process count does not grow with N (N=1 vs N=4)", () => {
  const [one, four] = [1, 4].map((n) => gitSpawns(scaledMixedRun(n)));
  assert.strictEqual(four, one, `N=4 (12 files) starts ${four} git processes, N=1 (3 files) starts ${one}`);
});
