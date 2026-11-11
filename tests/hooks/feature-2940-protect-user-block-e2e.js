"use strict";
// Tests: hooks/protect-user-block.js, bin/user-block-guard
// Tags: TL2, hook, protect-user-block, user-block-guard, user-block, gh, github, issue, subprocess, pretooluse, scope:issue-specific
// #2940 Step 10: the real hook spawns the real CLI, which asks a scripted stub gh (first on PATH)
// for the old issue. A title change on an issue holding a <user> block denies; a body that
// rewrites the block asks. No CLI stub: this is the whole chain the unit matrix stubs out.
// TL3 gap (what this test does NOT catch):
// - Claude Code reading the hook's deny / ask JSON and showing the approval dialog
// - the real GitHub GraphQL reply and `{owner}`/`{repo}` placeholder resolution (Step 9 measures)
const { caseBegin, caseEnd } = require("../lib/harness");

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const fx = require("./feature-2940-protect-user-block/fixture");
const { makeStubGh } = require("../lib/gh-scripted-stub");

after(() => fx.cleanup());

const HOOK = path.join(fx.REPO, "hooks", "protect-user-block.js");
const CLI = path.join(fx.REPO, "bin", "user-block-guard");
const R = "example-owner/example-repo";
const B = "<user>keep me</user>";
const stub = makeStubGh(fx.tempDir("e2e-stub"));
const issue = (body) => ({
  data: { repository: { issue: { id: "I_kw7", title: "Old title", body, comments: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } },
});

// runChain(command, oldBody) -> { decision, reason, ghCalls, stdout, stderr }, from a neutral cwd.
function runChain(command, oldBody) {
  assert.ok(fs.existsSync(HOOK) && fs.existsSync(CLI), "hook or CLI is not present (expected before write-code)");
  stub.setSpec({ rules: [{ match: "graphql", stdout: issue(oldBody) }], fallback: { exit: 1, stderr: "unscripted gh call" } });
  stub.resetCalls();
  const work = fx.tempDir("e2e-run");
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (name.toUpperCase() === "PATH") delete env[name];
  Object.assign(env, stub.env, {
    AGENTS_STATE_DIR: path.join(work, "agents-state"),
    CLAUDE_TRANSCRIPT_BASE_DIR: path.join(work, "transcripts"),
  });
  fs.mkdirSync(env.CLAUDE_TRANSCRIPT_BASE_DIR);
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PROJECT_DIR", "GH_REPO"]) delete env[name];
  const done = childProcess.spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: work }),
    env, cwd: work, encoding: "utf8", timeout: fx.WAIT_CAP_MS,
  });
  return { ...done, ...fx.decisionOf(done.stdout), ghCalls: stub.calls() };
}

const fetched = (r) => r.ghCalls.some((c) => c.args[0] === "api" && c.args[1] === "graphql");

caseBegin("e2e-title-change-on-block-issue-denies", "hooks/protect-user-block.js");
test("gh issue edit 7 -t New on an issue whose body holds a <user> block is denied", () => {
  const r = runChain(`gh issue edit 7 -R ${R} -t New`, `intro\n${B}\n`);
  assert.strictEqual(r.decision, "deny", `${r.stdout}${r.stderr}`);
  assert.ok(fetched(r), `the CLI fetched the old issue through gh: ${JSON.stringify(r.ghCalls)}`);
  assert.ok(!r.ghCalls.some((c) => c.args[0] === "issue"), "the hook never runs the write itself");
});
caseEnd();

caseBegin("e2e-title-change-without-block-passes", "hooks/protect-user-block.js");
test("the same title change on an issue without a block gives no decision", () => {
  const r = runChain(`gh issue edit 7 -R ${R} -t New`, "intro only\n");
  assert.strictEqual(r.decision, "none", `${r.stdout}${r.stderr}`);
});
caseEnd();

caseBegin("e2e-body-rewrites-block-asks", "hooks/protect-user-block.js");
test("gh issue edit 7 -b with the block rewritten asks, and the reason names the <user> block", () => {
  const r = runChain(`gh issue edit 7 -R ${R} -b "intro\n<user>changed</user>\n"`, `intro\n${B}\n`);
  assert.strictEqual(r.decision, "ask", `${r.stdout}${r.stderr}`);
  assert.match(r.reason, /<user>/);
  assert.ok(fetched(r));
});
caseEnd();
