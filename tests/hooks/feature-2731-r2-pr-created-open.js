"use strict";
// Tests: hooks/pr-created-open.js
// Tags: TL2, hooks, pr-created, system-message-contract, scope:issue-specific
// #2731 S3-4: the pr-created systemMessage is the single fact line [pr-created] #<N> <url>;
// no "Click Allow" line (a PostToolUse hook shows no dialog) and no English sentence.
// TL3 gap (what this test does NOT catch):
// - the browser actually opening (SHOW_USER_VERIFIED_NO_BROWSER=1 skips it here)
// Closest-to-action mitigation: feature-pr-created-open.sh T8 pins the openInBrowser call.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-prc-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const HOOK = path.join(__dirname, "..", "..", "hooks", "pr-created-open.js");
function runHook(stdout) {
  const input = { session_id: "2731prc0-0000-4000-8000-000000000001", hook_event_name: "PostToolUse", tool_name: "Bash",
    tool_input: { command: 'gh pr create --title "t" --body "b"' }, tool_response: { exit_code: 0, stdout } };
  const env = { ...process.env, SHOW_USER_VERIFIED_NO_BROWSER: "1" };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  return JSON.parse(r.stdout || "{}").systemMessage || "";
}

caseBegin("pr-created-fact-line", "hooks/pr-created-open.js");
test("gh pr create success -> exactly [pr-created] #<N> <url>", () => {
  const url = "https://github.com/o/r/pull/2731";
  const msg = runHook(`Creating pull request\n${url}\n`);
  assert.strictEqual(msg, `[pr-created] #2731 ${url}`);
  C.assertSystemMessageContract(msg);
});
caseEnd();
