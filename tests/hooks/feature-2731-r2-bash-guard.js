"use strict";
// Tests: hooks/bash-guard.js
// Tags: TL2, hooks, bash-guard, system-message-contract, conv-lang, scope:issue-specific
// #2731 S3-10: the notify envelope shows the user only [bash-guard] <code>; the message moves to
// additionalContext with the CONV_LANG directive exactly once. The deny reason is prefixed once.
// Under english neither path carries the directive.
// TL3 gap (what this test does NOT catch):
// - the 5s hook timeout under a cold Node start on the real host
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
// preflight via bin/check-verification-gate.sh category: hook-registration.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-bg-"));
const HOME = path.join(TMP, "home");
fs.mkdirSync(path.join(HOME, ".claude"), { recursive: true });
fs.writeFileSync(path.join(HOME, ".claude", "settings.json"), '{"permissions":{"allow":[],"deny":[]}}\n');
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "bash-guard.js");
const SID = "sid-r2-bg-armed";
const STEPS = ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests",
  "review_tests", "run_tests", "review_security", "docs", "user_verification", "cleanup", "pre_final_report_gate"];

// A SETTLED session: otherwise the early-write-gate interlock silences the guard.
const STATE = path.join(process.env.WORKFLOW_STATE_DIR, `${SID}.json`);
fs.writeFileSync(STATE, JSON.stringify({ version: 1, session_id: SID, created_at: "2026-01-01T00:00:00.000Z", is_bugfix: false,
  git_branch: "feature/2731-r2", workflow_type: "wf-code",
  steps: Object.fromEntries(STEPS.map((s) => [s, { status: "complete", updated_at: null }])) }));
const inj = spawnSync(process.execPath, [path.join(REPO, "tests", "lib", "plan-approval-fixture.js"), "inject-complete", STATE,
  "clarify_intent", "outline", "detail"], { encoding: "utf8", timeout: 60000 });
if (inj.status !== 0) throw new Error(`plan-approval-fixture inject-complete failed: ${inj.stderr}`);

function runHook(command, lang) {
  const input = { session_id: SID, hook_event_name: "PreToolUse", cwd: TMP, tool_name: "Bash", tool_input: { command } };
  const env = { ...process.env, CONV_LANG: lang, HOME, USERPROFILE: HOME };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  return JSON.parse(String(r.stdout).trim() || "{}");
}
const NOTIFY_CMD = '"<<WORKFLOW_MARK_STEP_p1_complete>>"';
const DENY_CMD = "git status && ls";

caseBegin("bash-guard-notify-fact-line", "hooks/bash-guard.js");
test("notify (japanese): systemMessage is [bash-guard] <code>; additionalContext carries the message, prefixed once", () => {
  const j = runHook(NOTIFY_CMD, "japanese");
  assert.strictEqual(j.decision, "approve", `fixture: a notify verdict: ${JSON.stringify(j)}`);
  assert.ok(/^\[bash-guard\] [A-Z0-9-]+$/.test(j.systemMessage || ""), `fact line: ${j.systemMessage}`);
  C.assertSystemMessageContract(j.systemMessage);
  const ctx = (j.hookSpecificOutput || {}).additionalContext || "";
  assert.ok(C.prefixedOnce(ctx, "japanese"), `additionalContext prefixed once:\n${ctx}`);
});
test("notify (english): additionalContext carries no directive", () => {
  const j = runHook(NOTIFY_CMD, "english");
  assert.strictEqual(j.decision, "approve", "fixture: a notify verdict");
  const ctx = (j.hookSpecificOutput || {}).additionalContext || "";
  assert.ok(ctx.length > 0, "additionalContext is present");
  assert.strictEqual(C.countDirective(ctx), 0, `no directive under english:\n${ctx}`);
});
caseEnd();

caseBegin("bash-guard-deny-conv-lang", "hooks/bash-guard.js");
test("deny (japanese): the block reason is prefixed once and still names the rule", () => {
  const j = runHook(DENY_CMD, "japanese");
  assert.strictEqual(j.decision, "block", `fixture: a deny verdict: ${JSON.stringify(j)}`);
  assert.ok(C.prefixedOnce(j.reason, "japanese"), `reason prefixed once:\n${j.reason}`);
  assert.ok(j.reason.includes("Command-Line Issuance Discipline"), "the rule name survives the prefix");
});
test("deny (english): the block reason carries no directive", () => {
  const j = runHook(DENY_CMD, "english");
  assert.strictEqual(j.decision, "block", "fixture: a deny verdict");
  assert.strictEqual(C.countDirective(j.reason), 0, `no directive under english:\n${j.reason}`);
});
caseEnd();
