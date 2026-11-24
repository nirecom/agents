"use strict";
// Tests: hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer/audit-run.js, hooks/workflow-mark/reset-handler.js
// Tags: TL2, scope:issue-specific, supervisor, audit
// #2795 (via #2853): per-stage audit run counts. A gate arm with count_tr counts once per new
// run, never on the idempotent return; RESET_FROM_<plan step> zeroes that stage and later.
// TL3 gap (what this test does NOT catch): the real Stop-hook arm path and a live RESET_FROM
// echo routed by Claude Code are not driven; armAuditRun and the reset handler are called in process.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2795-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
for (const k of ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", "WORKFLOW_SESSION_ID"]) delete process.env[k];
process.on("exit", () => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { make, mod } = require("./feature-2709-approval-bypass-closure/fixture");
const show = (v) => JSON.stringify(v);
const F = make({ TMP, CFG, eq: assert.deepStrictEqual, ok: assert.ok, show });
const AR = mod("hooks/lib/supervisor-state-writer/audit-run.js");
const schema = mod("hooks/lib/supervisor-state-schema.js");

const counts = (sid) => { const s = F.supState(sid); return (s && s.audit && s.audit.audit_run_counts) || null; };
function seedCounts(sid, c) {
  const st = schema.createEmptyState(sid);
  st.audit.audit_run_counts = Object.assign({}, c);
  const p = F.writer.getStatePath(sid, { forWrite: true });
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(st));
}
const git = (dir, ...args) => spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });

caseBegin("arm-with-count-tr-counts-a-new-run", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(a) a new run armed with count_tr TR2 adds one to TR2", () => {
  const sid = F.nextSid("a");
  const r = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2" });
  assert.ok(r.ok, `arm failed: ${show(r)}`);
  assert.deepStrictEqual(counts(sid), { TR1: 0, TR2: 1, TR3: 0 });
});
caseEnd();

caseBegin("idempotent-return-does-not-count", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(b) the idempotent guard returns the in-flight run without counting", () => {
  const sid = F.nextSid("b");
  const first = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2" });
  const again = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2" });
  assert.strictEqual(again.audit_run_id, first.audit_run_id, "same in-flight run returned");
  assert.strictEqual((counts(sid) || {}).TR2, 1, `counts ${show(counts(sid))}`);
});
caseEnd();

caseBegin("input-version-change-keeps-counting", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(c) a changed input_version does not restart the count", () => {
  const sid = F.nextSid("c");
  const repo = path.join(TMP, "repo-c");
  gitInit(repo);
  git(repo, "checkout", "-q", "-b", "main");
  fs.writeFileSync(path.join(repo, "a.txt"), "one\n");
  git(repo, "add", "a.txt");
  git(repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init");
  git(repo, "checkout", "-q", "-b", "feature");
  fs.writeFileSync(path.join(repo, "a.txt"), "two\n");
  const r1 = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2", cwd: repo });
  AR.finalizeAuditRun(sid, { audit_run_id: r1.audit_run_id, verdict: "CONTINUE", verdict_summary: "ok" });
  fs.writeFileSync(path.join(repo, "a.txt"), "three\n");
  const r2 = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2", cwd: repo });
  assert.notStrictEqual(r2.audit_run_id, r1.audit_run_id, "a second run was armed");
  const ledger = F.supState(sid).audit.ledger;
  const iv = ledger.map((e) => e.input_version);
  assert.ok(iv[0] && iv[1] && iv[0] !== iv[1], `fixture must vary input_version; got ${show(iv)}`);
  assert.strictEqual((counts(sid) || {}).TR2, 2, `counts ${show(counts(sid))}`);
});
caseEnd();

caseBegin("reset-from-outline-zeroes-tr2-and-tr3", "hooks/workflow-mark/reset-handler.js");
test("(d) a successful RESET_FROM_outline zeroes TR2 and TR3 and keeps TR1", () => {
  F.setConfig("on", "on", "on");
  const sid = F.seedWf("d", ["clarify_intent"]);
  seedCounts(sid, { TR1: 2, TR2: 3, TR3: 1 });
  const msg = F.reset(sid, "outline");
  assert.strictEqual(F.events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  assert.deepStrictEqual(counts(sid), { TR1: 2, TR2: 0, TR3: 0 });
});
caseEnd();

caseBegin("reset-from-write-code-keeps-counts", "hooks/workflow-mark/reset-handler.js");
test("(e) RESET_FROM_write_code leaves the plan-stage counts alone", () => {
  F.setConfig("on", "on", "on");
  const sid = F.seedWf("e", ["clarify_intent", "outline", "detail"]);
  seedCounts(sid, { TR1: 2, TR2: 3, TR3: 1 });
  const msg = F.reset(sid, "write_code");
  assert.strictEqual(F.events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  assert.deepStrictEqual(counts(sid), { TR1: 2, TR2: 3, TR3: 1 });
});
caseEnd();

caseBegin("refused-reset-keeps-counts", "hooks/workflow-mark/reset-handler.js");
test("(f) a reset refused as unapproved leaves the counts alone", () => {
  F.setConfig("on", "on", "on");
  const sid = F.seedWf("f", ["clarify_intent"]);
  seedCounts(sid, { TR1: 2, TR2: 3, TR3: 1 });
  const msg = F.reset(sid, "detail");
  assert.ok(/RESET_FROM_detail refused/i.test(msg), `reset refused; got ${show(msg)}`);
  assert.deepStrictEqual(counts(sid), { TR1: 2, TR2: 3, TR3: 1 });
});
caseEnd();

caseBegin("counts-are-not-shared-across-sessions", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(g) counting in session A leaves session B and AUDIT_DEFAULTS at zero", () => {
  const a = F.nextSid("ga");
  const b = F.nextSid("gb");
  AR.armAuditRun(a, { tr_ids: ["TR1"], cause: "pre-confirm:clarify_intent", count_tr: "TR1" });
  AR.armAuditRun(b, { tr_ids: ["TR4"], cause: "step-complete:write_code" });
  assert.strictEqual((counts(a) || {}).TR1, 1, `session A ${show(counts(a))}`);
  assert.deepStrictEqual(counts(b), { TR1: 0, TR2: 0, TR3: 0 });
  assert.deepStrictEqual(AR.AUDIT_DEFAULTS.audit_run_counts, { TR1: 0, TR2: 0, TR3: 0 });
  const st = {};
  AR.auditOf(st);
  assert.notStrictEqual(st.audit.audit_run_counts, AR.AUDIT_DEFAULTS.audit_run_counts, "default object copied");
});
caseEnd();

caseBegin("partial-counts-read-missing-tr-as-zero", "hooks/lib/supervisor-state-writer/audit-run.js");
test("edge: an existing state missing some TRs reads them as 0", () => {
  const st = { audit: { audit_run_counts: { TR2: 4 } } };
  const audit = AR.auditOf(st);
  assert.deepStrictEqual(audit.audit_run_counts, { TR1: 0, TR2: 4, TR3: 0 });
});
caseEnd();

caseBegin("schema-rejects-malformed-run-counts", "hooks/lib/supervisor-state-schema.js");
test("schema: audit_run_counts must be an object of non-negative integers", () => {
  const empty = schema.createEmptyState("f2795-schema");
  assert.deepStrictEqual(empty.audit.audit_run_counts, { TR1: 0, TR2: 0, TR3: 0 }, "initial literal carries the counts");
  assert.ok(schema.validate(empty).ok, `empty state validates: ${show(schema.validate(empty))}`);
  const cases = [
    { name: "not-an-object", value: 3 },
    { name: "array", value: [1] },
    { name: "negative", value: { TR1: -1, TR2: 0, TR3: 0 } },
    { name: "non-integer", value: { TR1: 0, TR2: 1.5, TR3: 0 } },
    { name: "string-value", value: { TR1: "1", TR2: 0, TR3: 0 } },
  ];
  for (const { name, value } of cases) {
    const st = schema.createEmptyState("f2795-schema");
    st.audit.audit_run_counts = value;
    assert.strictEqual(schema.validate(st).ok, false, `${name}: validate must reject ${show(value)}`);
  }
});
caseEnd();

// #3144 C2 (S2-7): armCore opts.findings — the destination / fallback record lands in the arm's own commit.
const NOTE = { categories: ["workflow"], severity: "notice", detail: "fixture route record", reporter: "route:pm-dest" };
const findingsOf = (sid) => { const s = F.supState(sid); return (s && s.audit && Array.isArray(s.audit.findings)) ? s.audit.findings : []; };
const ledgerLen = (sid) => { const s = F.supState(sid); return (s && s.audit && Array.isArray(s.audit.ledger)) ? s.audit.ledger.length : 0; };

caseBegin("C2 armCore findings are written with a new run and name its run id", "hooks/lib/supervisor-state-writer/audit-run.js");
test("C2 armCore findings: a new run carries its findings, each detail naming the run id", () => {
  const sid = F.nextSid("f1");
  const r = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2", findings: [NOTE] });
  assert.ok(r.ok, `arm failed: ${show(r)}`);
  const mine = findingsOf(sid).filter((f) => f.reporter === "route:pm-dest");
  assert.strictEqual(mine.length, 1, show(findingsOf(sid)));
  assert.ok(mine[0].detail.includes(r.audit_run_id), `detail names ${r.audit_run_id}: ${show(mine[0])}`);
  assert.ok(typeof mine[0].timestamp === "string" && mine[0].timestamp !== "", "timestamp stamped");
  assert.strictEqual(F.supState(sid).audit.audit_run_id, r.audit_run_id, "finding and run are in one state");
});
caseEnd();

caseBegin("C2 armCore rejects an invalid finding without arming or counting", "hooks/lib/supervisor-state-writer/audit-run.js");
test("C2 armCore findings: one invalid finding -> ok:false, no ledger entry, no count, no finding", () => {
  for (const bad of [{ categories: ["workflow"], severity: "bogus", detail: "x", reporter: "route:pm-dest" }, { detail: "no severity" }, "not-an-object"]) {
    const sid = F.nextSid("f2");
    const r = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2", findings: [NOTE, bad] });
    assert.strictEqual(r.ok, false, `invalid finding ${show(bad)} must fail the arm: ${show(r)}`);
    assert.strictEqual(ledgerLen(sid), 0, "no ledger entry");
    assert.strictEqual(((counts(sid) || {}).TR2) || 0, 0, "no count");
    assert.strictEqual(findingsOf(sid).length, 0, "no finding written");
  }
});
caseEnd();

caseBegin("C2 armCore in-flight return adds no findings", "hooks/lib/supervisor-state-writer/audit-run.js");
test("C2 armCore findings: the idempotent in-flight return writes no finding", () => {
  const sid = F.nextSid("f3");
  const first = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2" });
  const again = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", count_tr: "TR2", findings: [NOTE] });
  assert.strictEqual(again.audit_run_id, first.audit_run_id);
  assert.strictEqual(findingsOf(sid).filter((f) => f.reporter === "route:pm-dest").length, 0, show(findingsOf(sid)));
});
caseEnd();
