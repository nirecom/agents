"use strict";
// tests/hooks/feat-gh-detect-origin-url-opts.js
// Tests: hooks/workflow-gate/gh-detect.js
// Tags: TL1, TL2, scope:common, forge, origin, timeout
// #299: originUrl(repoDir, {timeoutMs, spawnSync}) — the title hook bounds the git call with its
// own budget (ORIGIN_TIMEOUT_MS). Without opts the old 5000 ms bound and behaviour stay.

// TL3 gap: the real VS Code / Claude app title rendering is not observed; only the origin lookup
// the title hook depends on is checked.

const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "origin-url-"));
after(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
  restore();
});
const originUrl = (...a) => require(path.join(ROOT, "hooks", "workflow-gate", "gh-detect.js")).originUrl(...a);

// recorder(result) -> a spawnSync stand-in that records each call and answers `result`.
function recorder(result) {
  const calls = [];
  const fn = (cmd, args, opts) => { calls.push({ cmd, args, opts }); return result; };
  fn.calls = calls;
  return fn;
}

caseBegin("origin-url-without-opts-reads-real-origin", "hooks/workflow-gate/gh-detect.js");
test("O1 originUrl(repo) returns the origin URL", () => {
  const repo = path.join(tmp, "repo");
  gitInit(repo);
  const add = spawnSync("git", ["-C", repo, "remote", "add", "origin", "https://github.com/o/r.git"], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(add.status, 0, add.stderr);
  assert.strictEqual(originUrl(repo), "https://github.com/o/r.git");
});
test("O1 no origin -> null", () => assert.strictEqual(originUrl(path.join(tmp, "nowhere")), null));
caseEnd();

caseBegin("origin-url-timeout-reaches-injected-spawn", "hooks/workflow-gate/gh-detect.js");
test("O2 timeoutMs reaches the injected spawnSync; URL is trimmed", () => {
  const sp = recorder({ status: 0, stdout: "  https://gitlab.com/g/p.git \n", stderr: "" });
  const got = originUrl("/fixture/repo", { timeoutMs: 1000, spawnSync: sp });
  assert.strictEqual(sp.calls.length, 1, "injected spawnSync called once");
  const c = sp.calls[0];
  assert.strictEqual(c.cmd, "git");
  assert.deepStrictEqual(c.args, ["-C", "/fixture/repo", "remote", "get-url", "origin"]);
  assert.strictEqual(c.opts && c.opts.timeout, 1000, JSON.stringify(c.opts));
  assert.strictEqual(got, "https://gitlab.com/g/p.git");
});
caseEnd();

caseBegin("origin-url-default-timeout-5000", "hooks/workflow-gate/gh-detect.js");
test("O3 injected spawnSync without timeoutMs keeps the 5000 ms default", () => {
  const sp = recorder({ status: 0, stdout: "https://github.com/o/r.git\n", stderr: "" });
  originUrl("/fixture/repo", { spawnSync: sp });
  const c = sp.calls[0] || {};
  assert.strictEqual(c.opts && c.opts.timeout, 5000, JSON.stringify(c.opts));
});
caseEnd();

caseBegin("origin-url-failures-answer-null", "hooks/workflow-gate/gh-detect.js");
for (const [label, result] of [
  ["error", { error: new Error("ETIMEDOUT"), status: null, stdout: "" }],
  ["non-zero status", { status: 128, stdout: "https://github.com/o/r.git\n" }],
  ["empty stdout", { status: 0, stdout: "  \n" }],
]) {
  test(`O4 ${label} -> null (spawn observed)`, () => {
    const sp = recorder(result);
    const got = originUrl("/fixture/repo", { timeoutMs: 1000, spawnSync: sp });
    assert.strictEqual(sp.calls.length, 1, "spawn observed");
    assert.strictEqual(got, null);
  });
}
caseEnd();
