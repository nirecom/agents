"use strict";
// Tests: hooks/lib/lint-commit-lang.js, hooks/pre-commit.d/checks/code-lang.js
// Tags: TL2, pre-commit, code-lang, spawn-count, real-git, node-precommit, scope:issue-specific
// #2507: the CODE_LANG check reads staged files from the pre-commit snapshot instead of one
// `git show :file` per file. check({files, read}) must start no git process, the git fallback
// must stay for callers without a snapshot, and the verdict and messages must not change.
// Child runs are counted with the tests/lib/node-spawn-log.js preload. Fixture text is synthetic.
const { isolate, gitInit, caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const LINT = path.join(REPO, "hooks", "lib", "lint-commit-lang.js");
const SNAP = path.join(REPO, "hooks", "pre-commit.d", "snapshot.js");
const CODE_LANG = path.join(REPO, "hooks", "pre-commit.d", "checks", "code-lang.js");
// NODE_OPTIONS reads a backslash as an escape, so the preload path is spelled with "/".
const SPAWN_LOG_JS = path.join(REPO, "tests", "lib", "node-spawn-log.js").replace(/\\/g, "/");
const ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "NODE_OPTIONS", "CLAUDE_CODE_SESSION_ID", "CODE_LANG", "CODE_LANG_EXCLUDE"];
// Synthetic CJK text, kept as escapes so this file stays ASCII.
const CJK = "テスト";

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-codelang-"));
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
  for (const k of ENV_DROP) delete env[k];
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

// A cfgDir whose .env sets CODE_LANG=english; lint-commit-lang finds it through AGENTS_MAIN_ROOT.
const CFG = tmpDir("cfg");
write(CFG, ".env", "CODE_LANG=english\n");

const RUNNER = path.join(tmpDir("runner"), "runner.js");
fs.writeFileSync(RUNNER, `"use strict";
const fs = require("fs");
const path = require("path");
const [mode, repo, filesJson, nullsJson] = process.argv.slice(2);
(async () => {
  const lint = require(${JSON.stringify(LINT)});
  let result;
  if (mode === "files") {
    const nulls = new Set(JSON.parse(nullsJson || "[]"));
    result = lint.check({ files: JSON.parse(filesJson), read: (f) => (nulls.has(f) ? null : fs.readFileSync(path.join(repo, f))) });
  } else if (mode === "git") {
    result = lint.check({});
  } else {
    const snap = await require(${JSON.stringify(SNAP)}).createSnapshot({ repoTop: repo, env: process.env });
    const ctx = { env: process.env, cfgDir: ${JSON.stringify(REPO)} };
    result = await require(${JSON.stringify(CODE_LANG)}).run({ context: ctx, snapshot: snap, files: snap.files() });
  }
  process.stdout.write(JSON.stringify(result));
})();
`);

// run(mode, repo, files, nulls) -> { result, gitLines } from a child Node with the spawn-log preload.
function run(mode, repo, files = [], nulls = []) {
  const log = path.join(tmpDir("log"), "spawn.log");
  const r = spawnSync(process.execPath, [RUNNER, mode, repo, JSON.stringify(files), JSON.stringify(nulls)], {
    cwd: repo,
    encoding: "utf8",
    timeout: 120000,
    env: baseEnv({ AGENTS_MAIN_ROOT: CFG, CODE_LANG: "english", NODE_OPTIONS: `--require "${SPAWN_LOG_JS}"`, TEST_NODE_SPAWN_LOG: log }),
  });
  assert.strictEqual(r.error, undefined, `spawn error ${r.error}`);
  assert.strictEqual(r.status, 0, `${mode}: rc ${r.status}\n${r.stdout}${r.stderr}`);
  const records = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const line = (rec) => [rec.cmd, ...rec.args].join(" ").replace(/\\/g, "/");
  assert.ok(records.some((rec) => rec.fn === "main" && /runner\.js/.test(line(rec))), "the preload reached the runner");
  const gitLines = records.filter((rec) => rec.fn !== "main" && /(^|\/)git(\.exe)?( |$)/.test(line(rec))).map(line);
  return { result: JSON.parse(r.stdout), gitLines };
}

// Staged: bad.js (CJK), ok.js (ASCII), ignored.js (CJK + bypass), bin.js (CJK + NUL), extra CJK files.
function stagedRepo(name, extra = 0) {
  const dir = tmpDir(name);
  gitInit(dir);
  git(dir, "config", "core.autocrlf", "false");
  write(dir, "bad.js", `const a = 1;\nconst msg = "${CJK}";\n`);
  write(dir, "ok.js", "const b = 2;\n");
  write(dir, "ignored.js", `// lang-check: ignore\nconst m = "${CJK}";\n`);
  write(dir, "bin.js", Buffer.concat([Buffer.from(`const c = "${CJK}";\n`), Buffer.from([0, 1, 2])]));
  for (let i = 0; i < extra; i++) write(dir, `more/x${i}.js`, `const v${i} = "${CJK}";\n`);
  git(dir, "add", "-A");
  return dir;
}

const FILES = ["bad.js", "ok.js", "ignored.js", "bin.js"];
const files = (res) => (res.violations || []).map((v) => `${v.file}:${v.lineNumber}`);

caseBegin("files-and-read-start-no-git", "hooks/lib/lint-commit-lang.js");
test("1 check({files, read}) starts no git process and still finds the violation", () => {
  const { result, gitLines } = run("files", stagedRepo("snap"), FILES);
  assert.deepStrictEqual(gitLines, [], `git started: ${gitLines.join("; ")}`);
  assert.deepStrictEqual(files(result), ["bad.js:2"], "lang-check: ignore and the NUL file are skipped");
});
caseEnd();

caseBegin("null-read-fails-open", "hooks/lib/lint-commit-lang.js");
test("2 a read that returns null skips that file and the rest is still judged", () => {
  const repo = stagedRepo("nullread", 1);
  const { result } = run("files", repo, [...FILES, "more/x0.js"], ["bad.js"]);
  assert.deepStrictEqual(files(result), ["more/x0.js:1"]);
});
caseEnd();

caseBegin("no-files-falls-back-to-git", "hooks/lib/lint-commit-lang.js");
test("3 without files the module falls back to git and reaches the same verdict", () => {
  const repo = stagedRepo("fallback");
  const viaGit = run("git", repo);
  assert.ok(viaGit.gitLines.length > 0, "the fallback lists and reads through git");
  assert.deepStrictEqual(viaGit.result, run("files", repo, FILES).result);
});
caseEnd();

caseBegin("status-d-excluded", "hooks/pre-commit.d/checks/code-lang.js");
test("4 status-D files are neither listed nor read", async () => {
  const saved = { ...process.env };
  Object.assign(process.env, { CODE_LANG: "english", AGENTS_MAIN_ROOT: CFG });
  delete process.env.CODE_LANG_EXCLUDE;
  const read = [];
  const status = { "bad.js": "A", "gone.js": "D", "ok.js": "M" };
  const body = { "bad.js": Buffer.from(`const msg = "${CJK}";\n`), "ok.js": Buffer.from("const b = 2;\n") };
  const snapshot = { status: (f) => status[f], content: (f) => (read.push(f), body[f] || null) };
  try {
    const r = await require(CODE_LANG).run({ context: { env: process.env, cfgDir: REPO }, snapshot, files: ["bad.js", "gone.js", "ok.js"] });
    assert.strictEqual(r.verdict, "block");
    assert.deepStrictEqual(read.sort(), ["bad.js", "ok.js"]);
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
});
caseEnd();

caseBegin("spawn-count-flat", "hooks/pre-commit.d/checks/code-lang.js");
test("5 through the snapshot the git process count does not grow with the file count (4 vs 24 files)", () => {
  const small = run("snapshot", stagedRepo("n0", 0));
  const large = run("snapshot", stagedRepo("n20", 20));
  assert.ok(small.gitLines.length > 0, "the snapshot itself reads through git");
  assert.strictEqual(large.gitLines.length, small.gitLines.length, `24 files: ${large.gitLines.join("; ")}\n4 files: ${small.gitLines.join("; ")}`);
});
caseEnd();

caseBegin("verdict-and-messages-unchanged", "hooks/pre-commit.d/checks/code-lang.js");
test("6 the code-lang verdict and messages are unchanged", () => {
  const { result } = run("snapshot", stagedRepo("msgs"));
  assert.strictEqual(result.verdict, "block");
  assert.deepStrictEqual(result.messages, [
    { stream: "stdout", text: `  bad.js:2: const msg = "${CJK}";` },
    { stream: "stdout", text: "" },
    { stream: "stdout", text: "Commit blocked: CODE_LANG policy violation in staged files." },
    { stream: "stdout", text: "Fix the issues above, or add 'lang-check: ignore' anywhere in the file to bypass." },
  ]);
  const many = run("snapshot", stagedRepo("many", 12)).result;
  assert.strictEqual(many.messages.filter((m) => /^ {2}\S+:\d+: /.test(m.text)).length, 10, "at most 10 violation lines");
});
caseEnd();

// stageThenEdit(name, staged, worktree) -> a repo whose index holds `staged` for x.js and whose
// working tree holds `worktree`, so the index and the working tree disagree.
function stageThenEdit(name, staged, worktree) {
  const dir = tmpDir(name);
  gitInit(dir);
  git(dir, "config", "core.autocrlf", "false");
  write(dir, "x.js", staged);
  git(dir, "add", "-A");
  write(dir, "x.js", worktree);
  return dir;
}
const BAD_BODY = `const a = 1;\nconst msg = "${CJK}";\n`;
const OK_BODY = "const a = 1;\nconst msg = \"ok\";\n";

caseBegin("staged-violation-dirty-worktree-blocks", "hooks/pre-commit.d/checks/code-lang.js");
test("7 a staged violation blocks although the working tree was fixed after staging", () => {
  const { result } = run("snapshot", stageThenEdit("c1a", BAD_BODY, OK_BODY));
  assert.strictEqual(result.verdict, "block");
  assert.deepStrictEqual(result.messages[0], { stream: "stdout", text: `  x.js:2: const msg = "${CJK}";` }, "the message quotes the staged line");
});
caseEnd();

caseBegin("staged-clean-dirty-worktree-passes", "hooks/pre-commit.d/checks/code-lang.js");
test("8 a clean staged file passes although the working tree holds a violation", () => {
  const { result } = run("snapshot", stageThenEdit("c1b", OK_BODY, BAD_BODY));
  assert.strictEqual(result.verdict, "pass");
  assert.deepStrictEqual(result.messages, []);
});
caseEnd();

caseBegin("status-m-violation-blocks", "hooks/pre-commit.d/checks/code-lang.js");
test("9 a committed file modified to a violation (status M) blocks", () => {
  const dir = tmpDir("c2");
  gitInit(dir);
  git(dir, "config", "core.autocrlf", "false");
  write(dir, "x.js", OK_BODY);
  git(dir, "add", "-A");
  git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init");
  write(dir, "x.js", BAD_BODY);
  git(dir, "add", "-A");
  assert.strictEqual(git(dir, "diff", "--cached", "--name-status").trim(), "M\tx.js", "the fixture stages a status-M file");
  const { result } = run("snapshot", dir);
  assert.strictEqual(result.verdict, "block");
  assert.deepStrictEqual(result.messages[0], { stream: "stdout", text: `  x.js:2: const msg = "${CJK}";` });
});
caseEnd();
