"use strict";
// Tests: hooks/show-plan-link.js
// Tags: TL1, TL2, hooks, plan-sync, breadcrumb, system-message-contract, conv-lang, scope:issue-specific
// #2731 S3-10: formatBreadcrumb emits fact lines only ([plan-file] <url|abs> + [plan-sync] <state>);
// the explanation sentences move to additionalContext, appended after the plan-link rows and wrapped
// in the CONV_LANG directive exactly once. Without additionalContext only the fact lines remain.
// TL3 gap (what this test does NOT catch):
// - a real plan-sync push (the sync result is injected through emitForArtifacts opts.sync)
// Closest-to-action mitigation: feature-show-plan-link/plan-sync-breadcrumb.sh drives the real hook.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-spl-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "show-plan-link.js");
const { formatBreadcrumb } = require(HOOK);
const ABS = "C:/plans/2731aaaa-detail.md";
const INIT = 'node "$AGENTS_MAIN_ROOT/bin/plan-sync-init"';

caseBegin("format-breadcrumb-fact-lines", "hooks/show-plan-link.js");
const ROWS = [
  ["pushed with URL", { status: "pushed", url: "https://example.invalid/o/r/blob/main/x-detail.md" }, "[plan-file] https://example.invalid/o/r/blob/main/x-detail.md"],
  ["pushed without URL", { status: "pushed" }, `[plan-file] ${ABS}\n[plan-sync] pushed no-blob-url`],
  ["off", { status: "off" }, `[plan-file] ${ABS}\n[plan-sync] off PLAN_SYNC_REMOTE_URL=`],
  ["not-provisioned", { status: "not-provisioned" }, `[plan-file] ${ABS}\n[plan-sync] not-provisioned ${INIT}`],
  ["failed with a reason", { status: "failed", reason: "push-rejected" }, `[plan-file] ${ABS}\n[plan-sync] push-rejected ${INIT}`],
  ["skipped not-regular-file", { status: "skipped", reason: "not-regular-file" }, `[plan-file] ${ABS}\n[plan-sync] skipped not-regular-file`],
  ["skipped budget-exhausted", { status: "skipped", reason: "budget-exhausted" }, `[plan-file] ${ABS}\n[plan-sync] skipped budget-exhausted`],
  ["skipped quiet host-mismatch", { status: "skipped", reason: "host-mismatch" }, `[plan-file] ${ABS}\n[plan-sync] not-sent host-mismatch`],
];
for (const [label, result, want] of ROWS) {
  test(`formatBreadcrumb(${label})`, () => {
    const got = formatBreadcrumb(result, ABS);
    assert.strictEqual(got, want);
    C.assertSystemMessageContract(got, label);
  });
}
caseEnd();

// emit(scene) runs emitForArtifacts in a child (it exits the process) with an injected sync result.
const DRIVER = path.join(TMP, "emit-driver.js");
fs.writeFileSync(DRIVER, [
  "const s = JSON.parse(process.env.R2_SCENE);",
  "if (s.breakContext) require(s.planLink).renderModelContext = () => { throw new Error('broken'); };",
  "const h = require(s.hook);",
  "const opts = { sync: () => s.result };",
  "if (s.budgetMs !== undefined) opts.budgetMs = s.budgetMs;",
  "h.emitForArtifacts([s.plan], { session_id: s.sid, cwd: s.cwd, tool_name: 'Write' }, opts);",
].join("\n"));
let seq = 0;
function emit(scene, lang) {
  const sid = `2731bbbb-${String(++seq).padStart(4, "0")}-4aaa-8bbb-000000000001`;
  const plan = path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-detail.md`);
  const s = { ...scene, sid, plan, cwd: TMP, hook: HOOK, planLink: path.join(REPO, "hooks", "lib", "plan-link.js") };
  const env = { ...process.env, R2_SCENE: JSON.stringify(s), CONV_LANG: lang, AGENTS_MAIN_ROOT: CFG, PLAN_SYNC_REMOTE_URL: "" };
  const r = spawnSync(process.execPath, [DRIVER], { cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `driver exit ${r.status}: ${r.stderr}`);
  const json = JSON.parse(r.stdout || "{}");
  return { json, msg: json.systemMessage || "", ctx: (json.hookSpecificOutput || {}).additionalContext, abs: path.resolve(plan) };
}
const afterDirective = (ctx) => String(ctx).slice(C.directiveSentence("japanese").length);

caseBegin("emit-explanation-moves-to-additional-context", "hooks/show-plan-link.js");
const EXPLAINED = [
  ["not-regular-file", { result: { status: "skipped", reason: "not-regular-file" } }, "skipped not-regular-file", /symlink|directory|missing|regular file/i],
  ["budget-exhausted", { result: { status: "pushed" }, budgetMs: 0 }, "skipped budget-exhausted", /budget|re-sav|retry/i],
  ["off", { result: { status: "off" } }, "off PLAN_SYNC_REMOTE_URL=", /not configured|PLAN_SYNC_REMOTE_URL/i],
];
for (const [label, scene, state, explanation] of EXPLAINED) {
  test(`emitForArtifacts(${label}, japanese): fact lines in systemMessage, explanation in additionalContext prefixed once`, () => {
    const r = emit(scene, "japanese");
    assert.strictEqual(r.msg.split("\n")[1], `[plan-sync] ${state}`, `systemMessage: ${r.msg}`);
    assert.ok(r.msg.startsWith("[plan-file] "), `systemMessage starts with [plan-file]: ${r.msg}`);
    C.assertSystemMessageContract(r.msg, `${label} systemMessage`);
    assert.strictEqual(typeof r.ctx, "string", "additionalContext is built");
    assert.ok(C.prefixedOnce(r.ctx, "japanese"), `additionalContext prefixed once:\n${r.ctx}`);
    assert.ok(explanation.test(afterDirective(r.ctx)), `the ${label} explanation is in additionalContext:\n${r.ctx}`);
  });
}
test("emitForArtifacts(not-regular-file, english): additionalContext carries no directive", () => {
  const r = emit(EXPLAINED[0][1], "english");
  assert.strictEqual(typeof r.ctx, "string", "additionalContext is built");
  assert.strictEqual(C.countDirective(r.ctx), 0, `no directive under english:\n${r.ctx}`);
});
caseEnd();

caseBegin("emit-fallback-without-additional-context", "hooks/show-plan-link.js");
test("renderModelContext throws -> only the systemMessage fact lines remain", () => {
  const r = emit({ result: { status: "skipped", reason: "not-regular-file" }, breakContext: true }, "japanese");
  assert.strictEqual(r.json.hookSpecificOutput, undefined, `no hookSpecificOutput: ${JSON.stringify(r.json)}`);
  assert.strictEqual(r.msg, `[plan-file] ${r.abs}\n[plan-sync] skipped not-regular-file`);
  C.assertSystemMessageContract(r.msg);
});
caseEnd();
