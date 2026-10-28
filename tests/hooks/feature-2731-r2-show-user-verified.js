"use strict";
// Tests: hooks/show-user-verified-context.js
// Tags: TL2, hooks, user-verified, system-message-contract, scope:issue-specific
// #2731 S3-10: the USER_VERIFIED dialog systemMessage carries facts only, one tagged line each:
// [user-verified] staged=<N>, then [user-verified] staged-file=<path> per file, then
// [user-verified] pr=<url> when a PR is found. No "Click Allow" line, no English labels.
// TL3 gap (what this test does NOT catch):
// - the real gh CLI answering pr view (a --require preload stubs it here)
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
// preflight via bin/check-verification-gate.sh category: hook-registration.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-uv-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "show-user-verified-context.js");
const PR_URL = "https://github.com/o/r/pull/42";
const PRELOAD = path.join(TMP, "gh-stub.js");
fs.writeFileSync(PRELOAD, [
  "const cp = require('child_process');",
  "const orig = cp.spawnSync;",
  "cp.spawnSync = function (cmd, args, opts) {",
  "  if (cmd === 'gh') return process.env.R2_GH_URL",
  "    ? { status: 0, stdout: process.env.R2_GH_URL + '\\n', stderr: '' }",
  "    : { status: 1, stdout: '', stderr: 'no pull requests found' };",
  "  return orig.apply(this, arguments);",
  "};",
].join("\n"));

function fixtureRepo(name, files) {
  const dir = path.join(TMP, name);
  fs.mkdirSync(dir);
  gitInit(dir);
  for (const f of files) {
    fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true });
    fs.writeFileSync(path.join(dir, f), "x\n");
    const r = spawnSync("git", ["-C", dir, "add", f], { encoding: "utf8" });
    assert.strictEqual(r.status, 0, `git add ${f}: ${r.stderr}`);
  }
  return dir.replace(/\\/g, "/");
}
function runHook(cwd, prUrl) {
  const input = { session_id: "2731uv00-0000-4000-8000-000000000001", hook_event_name: "PreToolUse",
    tool_name: "Bash", tool_input: { command: 'echo "<<WORKFLOW_USER_VERIFIED: verified the change>>"', cwd } };
  const env = { ...process.env, NODE_OPTIONS: `--require ${PRELOAD.replace(/\\/g, "/")}`, R2_GH_URL: prUrl || "" };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  return JSON.parse(r.stdout || "{}").systemMessage || "";
}

caseBegin("user-verified-fact-lines", "hooks/show-user-verified-context.js");
test("one staged file and a PR -> staged=1, staged-file=<path>, pr=<url>", () => {
  const cwd = fixtureRepo("one", ["src/a.txt"]);
  const msg = runHook(cwd, PR_URL);
  assert.strictEqual(msg, `[user-verified] staged=1\n[user-verified] staged-file=src/a.txt\n[user-verified] pr=${PR_URL}`);
  C.assertSystemMessageContract(msg);
});
test("two staged files and no PR -> staged=2 and one staged-file line each, no pr line", () => {
  const cwd = fixtureRepo("two", ["a.txt", "b.txt"]);
  const msg = runHook(cwd, "");
  assert.strictEqual(msg, "[user-verified] staged=2\n[user-verified] staged-file=a.txt\n[user-verified] staged-file=b.txt");
  C.assertSystemMessageContract(msg);
});
test("nothing staged -> the single line staged=0", () => {
  const cwd = fixtureRepo("none", []);
  const msg = runHook(cwd, "");
  assert.strictEqual(msg, "[user-verified] staged=0");
  C.assertSystemMessageContract(msg);
});
caseEnd();
