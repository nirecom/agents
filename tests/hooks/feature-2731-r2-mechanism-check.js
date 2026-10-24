"use strict";
// Tests: hooks/user-prompt-submit-mechanism-check.js
// Tags: TL2, hooks, mechanism-failure, user-prompt-submit, system-message-contract, conv-lang, scope:issue-specific
// #2731 S3-8: the stall notice splits in two. systemMessage is the fact line
// [mechanism-failure] <id>, <id>; the full explanation goes to additionalContext with the
// CONV_LANG directive exactly once (none under english).
// TL3 gap (what this test does NOT catch):
// - the model relaying the explanation to the user in the injected language
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
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-mech-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "user-prompt-submit-mechanism-check.js");
const wf = require(path.join(REPO, "hooks", "workflow-state", "state-io"));
const CA = require(path.join(REPO, "hooks", "workflow-state", "completion-approval"));
const PA = require("../lib/plan-approval-fixture");
const TTL_MS = 4 * 60 * 60 * 1000;

// seedStall(sid) — the #1979 shape: write_tests in_progress, its events aged past the in-flight TTL.
function seedStall(sid) {
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete"]) {
    if (CA.isApprovalGatedStep(s)) PA.approveLive(sid, s);
    wf.markStep(sid, s, "complete");
  }
  wf.markStep(sid, "write_tests", "in_progress");
  const p = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
  const st = JSON.parse(fs.readFileSync(p, "utf8"));
  const at = new Date(Date.now() - TTL_MS - 60000).toISOString();
  for (const e of st.events || []) if (e.step === "write_tests") e.at = at;
  fs.writeFileSync(p, JSON.stringify(st));
}
function runHook(sid, lang) {
  const input = { session_id: sid, transcript_path: "", prompt: "where are we?", hook_event_name: "UserPromptSubmit" };
  const env = { ...process.env, CONV_LANG: lang, AGENTS_MAIN_ROOT: CFG };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  const json = JSON.parse(r.stdout || "{}");
  return { json, msg: json.systemMessage || "", ctx: (json.hookSpecificOutput || {}).additionalContext || "" };
}

caseBegin("mechanism-failure-fact-line", "hooks/user-prompt-submit-mechanism-check.js");
test("japanese: systemMessage is [mechanism-failure] <id>; additionalContext carries the explanation, prefixed once", () => {
  seedStall("r2mechja");
  const r = runHook("r2mechja", "japanese");
  assert.strictEqual(r.json.blocks, true, `fixture: the stall is surfaced: ${JSON.stringify(r.json)}`);
  assert.ok(/^\[mechanism-failure\] [^\n]+$/.test(r.msg), `single fact line: ${r.msg}`);
  assert.ok(r.msg.includes("write_tests"), "the stalled step id is named");
  C.assertSystemMessageContract(r.msg);
  assert.ok(C.prefixedOnce(r.ctx, "japanese"), `additionalContext prefixed once:\n${r.ctx}`);
  assert.ok(r.ctx.includes("write_tests") && /stall/i.test(r.ctx), "the explanation names the step and the stall");
});
test("english: additionalContext carries the explanation without the directive", () => {
  seedStall("r2mechen");
  const r = runHook("r2mechen", "english");
  assert.strictEqual(r.json.blocks, true, "fixture: the stall is surfaced");
  assert.ok(r.msg.startsWith("[mechanism-failure] "), `fact line: ${r.msg}`);
  assert.strictEqual(C.countDirective(r.ctx), 0, `no directive under english:\n${r.ctx}`);
  assert.ok(/stall/i.test(r.ctx), "the explanation is still in additionalContext");
});
caseEnd();
