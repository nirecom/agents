"use strict";
// Tests: hooks/confirm-checkpoint.js, hooks/lib/confirm-continuation.js
// Tags: TL1, TL2, hooks, confirm-checkpoint, system-message-contract, conv-lang, scope:issue-specific, model-facing
// #2731 S3-3: the CONFIRM dialog systemMessage carries facts only ([<stage>] <url> (<abs>) / <abs> /
// plan-file=none), while the explanation goes to the additionalContext, which carries the CONV_LANG
// directive exactly once. The deny reason (#2729 present-again) is prefixed once.
// TL3 gap (what this test does NOT catch):
// - how the real permission dialog renders the systemMessage above Allow / Deny
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
const RS = require("../lib/presentation-receipt-seed");
const CE = require("../lib/confirm-env-fixture");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "r2-confirm-"));
const TDIR = path.join(TMP, "t");
const TBASE = path.join(TMP, "transcript-base");
for (const d of [TDIR, TBASE]) fs.mkdirSync(d);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });
// #2726/#2729: the plan-stage flags come from $AGENTS_MAIN_ROOT/.env only.
const CFG = CE.confirmEnvRoot(TMP, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_SYNC_REMOTE_URL: "" });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "confirm-checkpoint.js");
const { renderMessage } = require(HOOK);

let seq = 0;
function newSession(stage) {
  const sid = `2731cccc-${String(++seq).padStart(4, "0")}-4aaa-8bbb-${String(process.pid % 1e12).padStart(12, "0")}`;
  const plan = CE.withConfirmEnv(CFG, () => RS.canonicalPlan(sid, stage));
  fs.mkdirSync(path.dirname(plan), { recursive: true });
  fs.writeFileSync(plan, `# ${stage} plan\n\nSynthetic plan body.\n`);
  return { sid, plan };
}
// seed(s, stage) -> the presentation receipt the Stop hook would write (plan-sync off: a path receipt).
function seed(s, stage) {
  const p = CE.withConfirmEnv(CFG, () => RS.seedReceipt(s.sid, stage), { PLAN_SYNC_REMOTE_URL: "" });
  assert.ok(p, `fixture: a receipt was seeded for ${stage}`);
}
// runHook(s, stage, lang, nodeArgs) -> the hook's parsed output; nodeArgs go before the hook path (e.g. ["-r", preload]).
function runHook(s, stage, lang, nodeArgs = []) {
  const input = { session_id: s.sid, transcript_path: path.join(TDIR, "absent.jsonl"), hook_event_name: "PreToolUse", cwd: TDIR,
    tool_name: "Bash", tool_input: { command: `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}: approve the ${stage} plan>>"` } };
  const env = Object.assign(CE.childEnvWith(CFG), { PLAN_SYNC_REMOTE_URL: "", CLAUDE_TRANSCRIPT_BASE_DIR: TBASE, CONV_LANG: lang });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, nodeArgs.concat([HOOK]), { input: JSON.stringify(input), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `hook exit ${r.status}: ${r.stderr}`);
  const json = r.stdout ? JSON.parse(r.stdout) : {};
  const hso = json.hookSpecificOutput || {};
  return { json, msg: json.systemMessage || "", ctx: hso.additionalContext || "", deny: hso.permissionDecision === "deny" };
}

caseBegin("render-message-fact-lines", "hooks/confirm-checkpoint.js");
test("renderMessage: url + path -> [<stage>] <url> (<abs>)", () => {
  const got = renderMessage("detail", "C:/plans/s-detail.md", "https://example.invalid/o/r/blob/main/s-detail.md");
  assert.strictEqual(got, "[detail] https://example.invalid/o/r/blob/main/s-detail.md (C:/plans/s-detail.md)");
  C.assertSystemMessageContract(got);
});
test("renderMessage: path only -> [<stage>] <abs>", () => {
  const got = renderMessage("outline", "/home/u/.workflow-plans/s-outline.md", null);
  assert.strictEqual(got, "[outline] /home/u/.workflow-plans/s-outline.md");
  C.assertSystemMessageContract(got);
});
test("renderMessage: no path -> [<stage>] plan-file=none", () => {
  const got = renderMessage("intent", null, null);
  assert.strictEqual(got, "[intent] plan-file=none");
  C.assertSystemMessageContract(got);
});
caseEnd();

caseBegin("dialog-pass-conv-lang", "hooks/confirm-checkpoint.js");
test("pass (japanese): systemMessage is the single fact line; additionalContext carries the directive once", () => {
  const s = newSession("detail");
  seed(s, "detail");
  const r = runHook(s, "detail", "japanese");
  assert.ok(!r.deny, `fixture: a seeded presentation receipt passes: ${JSON.stringify(r.json)}`);
  assert.ok(/^\[detail\] \S+$/.test(r.msg) && r.msg.endsWith(`${s.sid}-detail.md`), `fact line: ${r.msg}`);
  C.assertSystemMessageContract(r.msg);
  assert.ok(C.prefixedOnce(r.ctx, "japanese"), `additionalContext prefixed once:\n${r.ctx}`);
});
test("pass (english): additionalContext carries no directive", () => {
  const s = newSession("detail");
  seed(s, "detail");
  const r = runHook(s, "detail", "english");
  assert.ok(!r.deny, `fixture: pass: ${JSON.stringify(r.json)}`);
  assert.ok(r.ctx.length > 0, "additionalContext is present");
  assert.strictEqual(C.countDirective(r.ctx), 0, `no directive under english:\n${r.ctx}`);
});
caseEnd();

caseBegin("deny-conv-lang", "hooks/confirm-checkpoint.js");
test("deny (japanese, no receipt): the block reason and permissionDecisionReason are prefixed once; no systemMessage", () => {
  const s = newSession("outline");
  const r = runHook(s, "outline", "japanese");
  assert.ok(r.deny, `fixture: no receipt -> deny: ${JSON.stringify(r.json)}`);
  assert.ok(C.prefixedOnce(r.json.reason, "japanese"), `reason:\n${r.json.reason}`);
  assert.ok(C.prefixedOnce(r.json.hookSpecificOutput.permissionDecisionReason, "japanese"), "permissionDecisionReason");
  assert.strictEqual(r.msg, "", "a deny shows no dialog systemMessage");
});
test("deny (english, no receipt): the reason carries no directive", () => {
  const s = newSession("intent");
  const r = runHook(s, "intent", "english");
  assert.ok(r.deny, `fixture: deny: ${JSON.stringify(r.json)}`);
  assert.strictEqual(C.countDirective(r.json.reason), 0, `english reason:\n${r.json.reason}`);
  assert.ok(r.json.reason.startsWith("[confirm-plan] present"), "english reason is the unchanged body");
});
caseEnd();

// The continuation reasons are model-facing: CONV_LANG directive once under japanese, unchanged under english.
const CC = require("../../hooks/lib/confirm-continuation");
const STAGES = ["intent", "outline", "detail"];
const withLang = (lang, fn) => {
  const prev = process.env.CONV_LANG;
  process.env.CONV_LANG = lang;
  try { return fn(); } finally {
    if (prev === undefined) delete process.env.CONV_LANG;
    else process.env.CONV_LANG = prev;
  }
};

caseBegin("continue-reason-conv-lang", "hooks/lib/confirm-continuation.js");
for (const stage of STAGES) {
  test(`continueReason(${stage}): japanese -> directive once at the head; english -> no directive`, () => {
    const ja = withLang("japanese", () => CC.continueReason(stage));
    assert.ok(C.prefixedOnce(ja, "japanese"), `japanese reason starts with the directive once:\n${ja}`);
    assert.ok(ja.includes(`WORKFLOW_CONFIRM_${stage.toUpperCase()}`), "the sentinel form survives the prefix");
    const en = withLang("english", () => CC.continueReason(stage));
    assert.strictEqual(C.countDirective(en), 0, `english reason carries no directive:\n${en}`);
    assert.ok(en.startsWith("[confirm-plan] continue:"), "english reason is the unchanged body");
  });
}
caseEnd();

caseBegin("present-again-reason-conv-lang", "hooks/lib/confirm-continuation.js");
for (const stage of STAGES) {
  for (const cause of ["no-receipt", "not-last", "unpublished"]) {
    test(`presentAgainReason(${stage}, ${cause}): japanese -> directive once at the head; english -> no directive`, () => {
      const ja = withLang("japanese", () => CC.presentAgainReason(stage, cause));
      assert.ok(C.prefixedOnce(ja, "japanese"), `japanese reason starts with the directive once:\n${ja}`);
      assert.ok(ja.includes(`present the ${stage} plan again (${cause})`), "the reason body survives the prefix");
      const en = withLang("english", () => CC.presentAgainReason(stage, cause));
      assert.strictEqual(C.countDirective(en), 0, `english reason carries no directive:\n${en}`);
      assert.ok(en.startsWith(`[confirm-plan] present the ${stage} plan again`), "english reason is the unchanged body");
    });
  }
}
caseEnd();

// #2804: when the shared wording cannot load, emitDeny still denies with its inline fallback reason.
// The preload (written inside TMP) makes every require of hooks/lib/confirm-continuation.js throw.
const NO_CC = path.join(TMP, "no-confirm-continuation.js");
fs.writeFileSync(NO_CC, [
  "\"use strict\";",
  "const Module = require(\"module\");",
  "const orig = Module._load;",
  "Module._load = function (request, parent, isMain) {",
  "  let f = \"\";",
  "  try { f = Module._resolveFilename(request, parent, isMain); } catch (_) { return orig.apply(this, arguments); }",
  "  if (/[\\\\/]hooks[\\\\/]lib[\\\\/]confirm-continuation\\.js$/.test(f)) throw new Error(\"injected: confirm-continuation unavailable\");",
  "  return orig.apply(this, arguments);",
  "};",
  "",
].join("\n"));

caseBegin("deny-fallback-without-shared-wording", "hooks/confirm-checkpoint.js");
for (const stage of STAGES) {
  test(`deny fallback (${stage}, english, no receipt): the inline reason names the cause, plan-link and the continue prompt`, () => {
    const s = newSession(stage);
    const r = runHook(s, stage, "english", ["-r", NO_CC]);
    assert.ok(r.deny, `fixture: no receipt -> deny: ${JSON.stringify(r.json)}`);
    const reason = r.json.reason || "";
    assert.ok(reason.startsWith(`[confirm-plan] CONFIRM_${stage.toUpperCase()} denied (no-receipt): present the plan again`), `fallback head:\n${reason}`);
    assert.ok(reason.includes(`(plan-link --stage ${stage})`), `plan-link command:\n${reason}`);
    assert.ok(reason.includes("on a \"[confirm-plan] continue:\" prompt emit only the echo"), `continue prompt:\n${reason}`);
    assert.ok(!reason.includes(`present the ${stage} plan again (no-receipt)`), `the shared wording was not used:\n${reason}`);
    assert.strictEqual(r.json.hookSpecificOutput.permissionDecisionReason, reason, "permissionDecisionReason equals the block reason");
    assert.strictEqual(C.countDirective(reason), 0, `english fallback carries no directive:\n${reason}`);
    assert.strictEqual(r.msg, "", "a deny shows no dialog systemMessage");
  });
}
test("deny fallback (outline, japanese, no receipt): the inline reason is prefixed once", () => {
  const s = newSession("outline");
  const r = runHook(s, "outline", "japanese", ["-r", NO_CC]);
  assert.ok(r.deny, `fixture: deny: ${JSON.stringify(r.json)}`);
  assert.ok(r.json.reason.includes("CONFIRM_OUTLINE denied (no-receipt)"), `fallback body:\n${r.json.reason}`);
  assert.ok(C.prefixedOnce(r.json.reason, "japanese"), `reason prefixed once:\n${r.json.reason}`);
});
caseEnd();
