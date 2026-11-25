"use strict";
// Tests: hooks/show-plan-link.js, hooks/show-plan-link/scan-breadcrumb.js
// Tags: TL1, TL2, hooks, plan-sync, breadcrumb, system-message-contract, scan-outbound, scope:issue-specific
// #3150 T-D: a plan-sync failure whose reason starts with "scan-" always shows (a) the reason,
// (b) up to 5 `rel:line [kind]` findings plus `+N more`, (c) the way out — .private-info-allowlist
// for scan-blocked, plan-sync-scan-skip for scan-unavailable / scan-timeout — and never the
// plan-sync-init hint nor any matched text. The #2731 systemMessage contract (fact lines only)
// still holds; the explanation also reaches the model through additionalContext.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const C = require("../lib/system-message-contract");

const restore = isolate();
delete process.env.CLAUDE_CODE_SESSION_ID;
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3150-spl-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const REPO = path.resolve(__dirname, "..", "..");
const HOOK = path.join(REPO, "hooks", "show-plan-link.js");
const SCAN_MOD = path.join(REPO, "hooks", "show-plan-link", "scan-breadcrumb.js");
const { formatBreadcrumb } = require(HOOK);
const ABS = "C:/plans/3150aaaa-detail.md";
const T = { timeout: 60000 };
const SECRET = "f3150-matched-secret-text";

const finding = (i, rel) => ({ rel: rel || "3150aaaa-detail.md", line: i, kind: i % 2 ? "blocklist" : "path" });
const failedOf = (reason, findings, extra) => ({ status: "failed", reason, findings, ...(extra || {}) });
const WAY_OUT = { "scan-blocked": /\.private-info-allowlist/, "scan-unavailable": /plan-sync-scan-skip/, "scan-timeout": /plan-sync-scan-skip/ };
const REASONS = Object.keys(WAY_OUT);

caseBegin("scan-breadcrumb-module", "hooks/show-plan-link/scan-breadcrumb.js");
test("scan-breadcrumb.js exports scanLines and scanNote", T, () => {
  assert.ok(fs.existsSync(SCAN_MOD), `module missing: ${path.relative(REPO, SCAN_MOD)}`);
  const m = require(SCAN_MOD);
  assert.strictEqual(typeof m.scanLines, "function");
  assert.strictEqual(typeof m.scanNote, "function");
});
caseEnd();

caseBegin("format-breadcrumb-scan-reasons", "hooks/show-plan-link.js");
for (const reason of REASONS) {
  test(`formatBreadcrumb(${reason}): reason, rel:line [kind], way out; no plan-sync-init`, T, () => {
    const findings = reason === "scan-blocked" ? [finding(2), finding(9, "c2-outline.md")] : [];
    const got = formatBreadcrumb(failedOf(reason, findings), ABS);
    assert.ok(got.startsWith(`[plan-file] ${ABS}\n`), got);
    assert.ok(got.includes(reason), `reason shown:\n${got}`);
    for (const f of findings) assert.ok(got.includes(`${f.rel}:${f.line} [${f.kind}]`), `finding ${f.rel}:${f.line} shown:\n${got}`);
    assert.match(got, WAY_OUT[reason], `way out shown:\n${got}`);
    assert.ok(!got.includes("plan-sync-init"), `no plan-sync-init hint:\n${got}`);
    C.assertSystemMessageContract(got, reason);
  });
}
test("scan-blocked with 7 findings: the first 5 and +2 more", T, () => {
  const findings = [1, 2, 3, 4, 5, 6, 7].map((i) => finding(i));
  const got = formatBreadcrumb(failedOf("scan-blocked", findings), ABS);
  for (const f of findings.slice(0, 5)) assert.ok(got.includes(`${f.rel}:${f.line} [${f.kind}]`), `shown ${f.line}:\n${got}`);
  for (const f of findings.slice(5)) assert.ok(!got.includes(`${f.rel}:${f.line} [`), `not shown ${f.line}:\n${got}`);
  assert.ok(got.includes("+2 more"), `+2 more:\n${got}`);
  C.assertSystemMessageContract(got, "seven findings");
});
test("scan-blocked with exactly 5 findings: no +N more", T, () => {
  const got = formatBreadcrumb(failedOf("scan-blocked", [1, 2, 3, 4, 5].map((i) => finding(i))), ABS);
  assert.ok(!/\+\d+ more/.test(got), got);
});
test("a stray matched field is never printed", T, () => {
  const f = { ...finding(3), matched: SECRET };
  const got = formatBreadcrumb(failedOf("scan-blocked", [f]), ABS);
  assert.ok(!got.includes(SECRET), got);
});
test("findings survive a truncated detail: they ride their own field", T, () => {
  const findings = [finding(4), finding(8)];
  const got = formatBreadcrumb(failedOf("scan-blocked", findings, { detail: "line a\nline b\nline c" }), ABS);
  for (const f of findings) assert.ok(got.includes(`${f.rel}:${f.line} [${f.kind}]`), got);
});
test("a non-scan failure keeps the plan-sync-init hint (unchanged)", T, () => {
  const got = formatBreadcrumb({ status: "failed", reason: "push-rejected" }, ABS);
  assert.strictEqual(got, `[plan-file] ${ABS}\n[plan-sync] push-rejected node "$AGENTS_MAIN_ROOT/bin/plan-sync-init"`);
});
caseEnd();

// emit(result) runs emitForArtifacts in a child (it exits the process) with an injected sync result.
const DRIVER = path.join(TMP, "emit-driver.js");
fs.writeFileSync(DRIVER, [
  "const s = JSON.parse(process.env.F3150_SCENE);",
  "const h = require(s.hook);",
  "h.emitForArtifacts([s.plan], { session_id: s.sid, cwd: s.cwd, tool_name: 'Write' }, { sync: () => s.result });",
].join("\n"));
let seq = 0;
function emit(result) {
  const sid = `3150bbbb-${String(++seq).padStart(4, "0")}-4aaa-8bbb-000000000001`;
  const plan = path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-detail.md`);
  const s = { result, sid, plan, cwd: TMP, hook: HOOK };
  const env = { ...process.env, F3150_SCENE: JSON.stringify(s), CONV_LANG: "english", AGENTS_MAIN_ROOT: CFG, PLAN_SYNC_REMOTE_URL: "" };
  const r = spawnSync(process.execPath, [DRIVER], { cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `driver exit ${r.status}: ${r.stderr}`);
  const json = JSON.parse(r.stdout || "{}");
  return { msg: json.systemMessage || "", ctx: String((json.hookSpecificOutput || {}).additionalContext || "") };
}

caseBegin("emit-scan-note-in-additional-context", "hooks/show-plan-link.js");
for (const reason of REASONS) {
  test(`emitForArtifacts(${reason}): systemMessage shows the facts, additionalContext carries the note`, T, () => {
    const findings = [finding(2), { ...finding(5, "c9-intent.md"), matched: SECRET }];
    const r = emit(failedOf(reason, findings));
    assert.ok(r.msg.includes(reason), `systemMessage reason:\n${r.msg}`);
    C.assertSystemMessageContract(r.msg, `${reason} systemMessage`);
    assert.ok(r.ctx.includes(reason), `additionalContext names the reason:\n${r.ctx}`);
    assert.match(r.ctx, WAY_OUT[reason], `additionalContext names the way out:\n${r.ctx}`);
    if (reason !== "scan-blocked") assert.match(r.ctx, /saved again/, `additionalContext says the plan is saved again:\n${r.ctx}`);
    assert.ok(!r.ctx.includes("plan-sync-init") && !r.msg.includes("plan-sync-init"), "no plan-sync-init hint");
    assert.ok(!r.ctx.includes(SECRET) && !r.msg.includes(SECRET), "no matched text anywhere");
  });
}
caseEnd();
