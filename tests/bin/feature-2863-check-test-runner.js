"use strict";
// Tests: bin/check-test-runner/cli.js
// Tags: TL1, bin, test-runner, cli, scope:issue-specific
// #2863 edit-time CLI: exit codes and output of check-test-runner over plain scripts and node:test
// files, the --rel contract, and the entry chosen by --rel rather than the copy's own name.
const { isolate } = require("../lib/harness");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2863-cli-"));
process.env.AGENTS_MAIN_ROOT = path.join(ROOT, "decoy");
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort */ }
});

const F = require("../hooks/feature-2863-test-runner/fixtures");
const REPO = path.resolve(__dirname, "..", "..");
const CLI = path.join(REPO, "bin", "check-test-runner", "cli.js");
const SH = path.join(REPO, "bin", "check-test-runner.sh").replace(/\\/g, "/");

// put(rel, body) — writes body to ROOT/<rel> and returns rel (the CLI runs with cwd ROOT).
function put(rel, body) {
  const abs = path.join(ROOT, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, body);
  return rel;
}
function cli(...args) {
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: ROOT, encoding: "utf8", env: process.env, timeout: 60000 });
  return { rc: r.status, out: r.stdout || "", err: r.stderr || "", show: `rc=${r.status} stdout=[${r.stdout}] stderr=[${r.stderr}]` };
}

const PLAIN = put("tests/bin/plain.js", F.BODY.plain);
const RUNNER = put("tests/bin/runner.js", F.BODY.nodeTest);

test("U1: a plain script exits 1 with the HIGH line on stdout", () => {
  const r = cli(PLAIN);
  assert.strictEqual(r.rc, 1, r.show);
  assert.strictEqual(r.out, `${F.highLine(PLAIN)}\n`, r.show);
});

test("U1: a node:test file exits 0 with no output", () => {
  const r = cli(RUNNER);
  assert.strictEqual(r.rc, 0, r.show);
  assert.strictEqual(r.out, "", r.show);
});

test("U1: several files: any plain script makes it 1 and names only that file", () => {
  const r = cli(RUNNER, PLAIN);
  assert.strictEqual(r.rc, 1, r.show);
  assert.ok(r.out.includes(F.highLine(PLAIN)) && !r.out.includes(RUNNER), r.show);
  assert.strictEqual(cli(RUNNER, put("tests/bin/import.js", F.BODY.importTest)).rc, 0);
});

test("U1: --rel with two files exits 2", () => {
  const r = cli("--rel", "tests/bin/x.js", PLAIN, RUNNER);
  assert.strictEqual(r.rc, 2, r.show);
  assert.strictEqual(r.out, "", r.show);
});

test("U1: a missing file exits 2", () => {
  const r = cli("tests/bin/absent.js");
  assert.strictEqual(r.rc, 2, r.show);
  assert.ok(r.err.includes("tests/bin/absent.js"), r.show);
});

test("U2: --rel decides the entry: a .txt copy judged as tests/bin/x.js is refused under that name", () => {
  const copy = put("snippet.txt", F.BODY.plain);
  const r = cli("--rel", "tests/bin/x.js", copy);
  assert.strictEqual(r.rc, 1, r.show);
  assert.strictEqual(r.out, `${F.highLine("tests/bin/x.js")}\n`, r.show);
  const bare = cli(copy);
  assert.strictEqual(bare.rc, 0, `without --rel the .txt is not a test entrypoint: ${bare.show}`);
  assert.strictEqual(bare.out, "", bare.show);
});

test("U2: --rel to a node:test copy exits 0", () => {
  const r = cli("--rel", "tests/bin/x.js", put("runner-copy.txt", F.BODY.nodeTest));
  assert.strictEqual(r.rc, 0, r.show);
});

test("U1: the bash adapter passes the arguments and the exit code through", () => {
  const r = spawnSync("bash", [SH, "--rel", "tests/bin/x.js", put("adapter.txt", F.BODY.plain)], {
    cwd: ROOT, encoding: "utf8", env: process.env, timeout: 60000,
  });
  assert.strictEqual(r.status, 1, `rc=${r.status} stdout=[${r.stdout}] stderr=[${r.stderr}]`);
  assert.ok(String(r.stdout).includes(F.highLine("tests/bin/x.js")), r.stdout);
});
