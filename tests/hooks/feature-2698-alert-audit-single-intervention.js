"use strict";
// Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/audit-arm.js, hooks/supervisor-guard/collect-audit-triggers.js, hooks/lib/supervisor-state-writer/audit-run.js, hooks/lib/audit-ledger.js
// Tags: TL2, hooks, supervisor, supervisor-guard, stop-hook, alert, audit, audit-arm, bundling, suppression, scope:issue-specific
// #2698 change 3: an audit launch instruction never appears as its own intervention right after
// an alert. 3-A bundles it into the alert block; 3-B arms without showing it while P (real user
// prompts since alert.last_run_at) is 0 or 1; 3-C shows the deferred ("unshown") run at the first
// Stop outside that window, superseding it when a new candidate exists.
// TL3 gap (what this test does NOT catch):
// - a live main conversation dispatching supervisor and supervisor-audit in the same turn
// Closest-to-action mitigation: the real supervisor-guard runs on a Stop stdin payload per scene.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const X = require("./feature-2698-supervisor/fixture");
const S = require("./feature-2698-supervisor/audit-scene");

const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = X.tmpRoot("single");
after(() => { restore(); X.rmRoot(ROOT); });

const now = () => new Date().toISOString();
const ARMED = () => ({ alert: { alert_phase: "pending", alert_armed_at: now(), alert_retry_count: 0 } });
const CUMSEV_ERROR = () => ({ alert: { alert_phase: "pending", cumulative_severity: "error", findings: [S.finding("error", "fixture error")] } });
// The alert review finished at LAST_RUN_AT; cumSev decides whether TR6 is a candidate.
const REVIEWED = (cumSev = null) => ({ alert: { alert_phase: "done", last_run_at: S.LAST_RUN_AT, cumulative_severity: cumSev } });
const dump = (r) => `status=${r.status} stdout=${r.stdout} stderr=${r.stderr}`;

function assertBundled(r, runId) {
  assert.strictEqual(r.status, 2, dump(r));
  assert.strictEqual(S.stdoutLines(r).length, 1, "exactly one block payload");
  const reason = S.reasonOf(r);
  assert.ok(S.ALERT_MARK.test(reason), `the alert block is kept (${reason.slice(0, 200)})`);
  assert.ok(reason.includes(`Run ID: ${runId}`), `the audit launch section for ${runId} is bundled (${reason.slice(-400)})`);
}

caseBegin("bundle-launch-into-alert-block", "hooks/supervisor-guard.js");
test("branch (3) alert armed + unconsumed edge -> one block carrying alert and launch; run shown", () => {
  const s = S.scene(ROOT, "b3", ARMED());
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assertBundled(r, "run-0001");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_phase, "pending");
  assert.strictEqual(typeof a.audit_dispatched_at, "string", "audit_dispatched_at is set in the arm commit");
});
test("branch (2) cumSev=error (alert not terminal) -> the same bundling", () => {
  const s = S.scene(ROOT, "b2", CUMSEV_ERROR());
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assertBundled(r, "run-0001");
  assert.strictEqual(typeof S.auditOf(s).audit_dispatched_at, "string");
});
test("Phase B source=l2 (audit done CONTINUE + cumSev=error) -> bundles a NEW run armed after the done CAS", () => {
  const s = S.scene(ROOT, "pbl2", CUMSEV_ERROR());
  S.armUnshown(s);
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "CONTINUE", verdict_summary: "ok" });
  S.completeWriteCode(s);
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assertBundled(r, "run-0002");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_run_id, "run-0002");
  assert.strictEqual(a.audit_phase, "pending");
  assert.strictEqual(typeof a.audit_dispatched_at, "string");
});
test("an unshown run + alert block -> that same run-id is bundled and marked shown, no new run", () => {
  const s = S.scene(ROOT, "unsh", ARMED());
  S.armUnshown(s);
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assertBundled(r, "run-0001");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_run_id, "run-0001");
  assert.strictEqual(a.run_seq, 1, "no new run minted");
  assert.strictEqual(typeof a.audit_dispatched_at, "string");
});
// l3 / both blocks already show an audit result, so they never carry a launch section (3-3).
for (const [source, sup] of [["l3", () => ({})], ["both", CUMSEV_ERROR]]) {
  test(`Phase B source=${source} (audit BLOCK) + an unconsumed edge -> no launch bundled, nothing marked shown`, () => {
    const s = S.scene(ROOT, `pb${source}`, sup());
    S.armUnshown(s);
    S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "BLOCK", verdict_summary: "audit-block-token" });
    S.completeWriteCode(s);
    const r = S.guard(s, S.turns(S.PROMPTS[0]));
    assert.strictEqual(r.status, 2, dump(r));
    const reason = S.reasonOf(r);
    assert.ok(reason.includes("audit-block-token"), `the audit BLOCK result is shown (${reason.slice(0, 200)})`);
    if (source === "both") assert.ok(S.ALERT_MARK.test(reason), "the alert reason is part of the both block");
    assert.ok(!/Run ID:/.test(reason), `no launch section in an ${source} block (${reason.slice(-300)})`);
    const a = S.auditOf(s);
    assert.strictEqual(a.run_seq, 1, "no new run armed");
    assert.notStrictEqual(typeof a.audit_dispatched_at, "string", "nothing marked shown");
  });
}
test("no candidate and no unshown run -> the alert reason is returned unchanged", () => {
  const s = S.scene(ROOT, "nocand", ARMED());
  // Consume the TR1 edge with a finished run and clear the slot: no edge, no TR6 (cumSev unset), nothing unshown.
  S.writer(s.dir, "armAuditRun", s.sid, { tr_ids: ["TR1"], transitions: [S.stepKey(s.dir, s.sid, "clarify_intent")], cause: "x", launch_shown: true });
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "CONTINUE", verdict_summary: "ok" });
  S.writer(s.dir, "writeAuditState", s.sid, { audit_phase: null });
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assert.strictEqual(r.status, 2, dump(r));
  const expected = JSON.parse(X.nodeEval(s.dir, `
const path = require("path");
const f = require(${JSON.stringify(X.lib("hooks/lib/supervisor-report-format.js"))});
const w = require(${JSON.stringify(X.lib("hooks/lib/supervisor-state-writer.js"))});
const sid = process.argv[2];
const sup = path.join(${JSON.stringify(X.REPO)}, "agents", "supervisor.md");
process.stdout.write(JSON.stringify(f.formatL2ArmedReason("scheduled-review", sid, null, sup, w.getStatePath(sid), sid)));`, [s.sid]));
  assert.strictEqual(S.reasonOf(r), expected, "the plain alert reason, byte for byte");
  assert.strictEqual(S.auditOf(s).run_seq, 1, "run_seq unchanged");
});
test("freeze (retry reaches the threshold) -> exit 0, no output, nothing marked shown", () => {
  const s = S.scene(ROOT, "frz", { alert: { alert_phase: "pending", alert_armed_at: now(), alert_retry_count: 1 } });
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  assert.notStrictEqual(typeof S.auditOf(s).audit_dispatched_at, "string", "no launch was shown");
});
caseEnd();

caseBegin("post-alert-suppression-window", "hooks/supervisor-guard/audit-arm.js");
test("P=0, edge candidate -> no block; armed as an unshown run", () => {
  const s = S.scene(ROOT, "p0e", REVIEWED());
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_phase, "pending", "the arm is not stopped");
  assert.strictEqual(a.audit_dispatched_at, null, "unshown");
});
test("P=0, TR6-only candidate (edges consumed) -> no block; armed as an unshown run", () => {
  const s = S.scene(ROOT, "p0t6", REVIEWED("error"));
  S.writer(s.dir, "armAuditRun", s.sid, { tr_ids: ["TR1"], transitions: [S.stepKey(s.dir, s.sid, "clarify_intent")], cause: "x" });
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "CONTINUE", verdict_summary: "ok" });
  S.writer(s.dir, "writeAuditState", s.sid, { audit_phase: null });
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_run_id, "run-0002", "TR6 armed");
  assert.strictEqual(a.audit_dispatched_at, null);
});
test("P=1 (route iii), no unshown run, edge -> no block; armed unshown", () => {
  const s = S.scene(ROOT, "p1e", REVIEWED());
  const r = S.guard(s, S.turns(S.PROMPTS[1]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  assert.strictEqual(S.auditOf(s).audit_dispatched_at, null);
  assert.strictEqual(S.auditOf(s).audit_phase, "pending");
});
test("P=1 with an unshown run + new edge -> no block, state unchanged, new edge left unconsumed", () => {
  const s = S.scene(ROOT, "p1u", REVIEWED());
  S.armUnshown(s);
  const edge = S.completeWriteCode(s);
  const before = S.auditOf(s);
  const r = S.guard(s, S.turns(S.PROMPTS[1]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_run_id, before.audit_run_id);
  assert.strictEqual(a.audit_dispatched_at, null);
  assert.ok(!a.consumed_transitions.includes(edge), `${edge} stays unconsumed`);
});
test("P undecidable (last prompt has no timestamp) -> the launch block is shown as today", () => {
  const s = S.scene(ROOT, "pnull", REVIEWED());
  const r = S.guard(s, S.turns(S.PROMPTS[1], { untimed: true }));
  assert.strictEqual(r.status, 2, dump(r));
  assert.ok(S.hasLaunch(S.reasonOf(r)));
});
test("no transcript at all (P null) -> the launch block is shown as today", () => {
  const s = S.scene(ROOT, "pnone", REVIEWED());
  const r = S.guard(s, null);
  assert.strictEqual(r.status, 2, dump(r));
  assert.ok(S.hasLaunch(S.reasonOf(r)));
});
test("no alert.last_run_at -> no suppression window; the launch block is shown", () => {
  const s = S.scene(ROOT, "nolr", {});
  const r = S.guard(s, S.turns(S.PROMPTS[0]));
  assert.strictEqual(r.status, 2, dump(r));
  assert.ok(S.hasLaunch(S.reasonOf(r)));
});
test("P=2 (outside the window), no unshown run, new edge on Stop -> the normal launch block is shown", () => {
  const s = S.scene(ROOT, "p2e", REVIEWED());
  const r = S.guard(s, S.turns(S.PROMPTS[2]));
  assert.strictEqual(r.status, 2, dump(r));
  assert.ok(S.hasLaunch(S.reasonOf(r)), S.reasonOf(r).slice(0, 300));
  assert.strictEqual(typeof S.auditOf(s).audit_dispatched_at, "string", "the launch is marked shown");
});
test("bundleAuditLaunch fail-open: a throwing state read returns the alert reason exactly", () => {
  const { bundleAuditLaunch } = require(X.lib("hooks/supervisor-guard/audit-bundle.js"));
  const reason = "alert-reason-sentinel";
  const deps = { sessionId: "sid-failopen", ctx: {}, readState: () => { throw new Error("boom"); } };
  assert.strictEqual(bundleAuditLaunch(reason, deps), reason);
  assert.strictEqual(bundleAuditLaunch(reason, {}), reason, "missing deps also fail open");
});
caseEnd();

caseBegin("release-unshown-run-outside-window", "hooks/lib/supervisor-state-writer/audit-run.js");
test("C2: P=2, unshown run + new edge -> one launch of a NEW run inheriting the old sub-checks; old run superseded", () => {
  const s = S.scene(ROOT, "c2e", REVIEWED());
  S.armUnshown(s);
  S.completeWriteCode(s);
  const r = S.guard(s, S.turns(S.PROMPTS[2]));
  assert.strictEqual(r.status, 2, dump(r));
  const reason = S.reasonOf(r);
  assert.ok(reason.includes("Run ID: run-0002"), reason.slice(0, 300));
  assert.ok(/run-0001/.test(reason.replace("Run ID: run-0002", "")), "the inherited-from line names run-0001");
  const a = S.auditOf(s);
  assert.strictEqual(a.audit_run_id, "run-0002");
  assert.strictEqual(typeof a.audit_dispatched_at, "string");
  const old = S.ledgerEntry(a, "run-0001");
  assert.ok(old && old.outcome === "superseded" && typeof old.terminal_at === "string", JSON.stringify(old));
  for (const id of ["intent-internal", "detail-code"]) assert.ok(a.pending_sub_checks.includes(id), `union keeps ${id}`);
});
test("C2: P=2, unshown run, no new candidate -> launch of the same run-id; marked shown", () => {
  const s = S.scene(ROOT, "c2n", REVIEWED());
  S.armUnshown(s);
  const r = S.guard(s, S.turns(S.PROMPTS[2]));
  assert.strictEqual(r.status, 2, dump(r));
  assert.ok(S.reasonOf(r).includes("Run ID: run-0001"));
  const a = S.auditOf(s);
  assert.strictEqual(a.run_seq, 1);
  assert.strictEqual(typeof a.audit_dispatched_at, "string");
});
test("C2: P=2 but a dialog turn -> silent; the next non-dialog Stop shows the run", () => {
  const s = S.scene(ROOT, "c2d", REVIEWED());
  S.armUnshown(s);
  const quiet = S.guard(s, S.turns(S.PROMPTS[2], { dialogLast: true }), "dlg");
  assert.strictEqual(quiet.status, 0, dump(quiet));
  assert.strictEqual(quiet.stdout.trim(), "");
  assert.strictEqual(S.auditOf(s).audit_dispatched_at, null);
  const shown = S.guard(s, S.turns([0, 2, 3, 4]), "next");
  assert.strictEqual(shown.status, 2, dump(shown));
  assert.ok(S.reasonOf(shown).includes("Run ID: run-0001"));
});
test("regression: a SHOWN pending run (audit_dispatched_at set) still blocks new arms idempotently", () => {
  const s = S.scene(ROOT, "shown", REVIEWED());
  S.armUnshown(s);
  S.writer(s.dir, "writeAuditState", s.sid, { audit_dispatched_at: now() });
  const edge = S.completeWriteCode(s);
  const r = S.guard(s, S.turns(S.PROMPTS[2]));
  assert.strictEqual(r.status, 0, dump(r));
  assert.strictEqual(r.stdout.trim(), "");
  const again = S.writer(s.dir, "armAuditRun", s.sid, { tr_ids: ["TR4"], transitions: [edge], launch_shown: true, cause: "x" });
  assert.strictEqual(again.run_id, "run-0001", "idempotent: the existing run is returned");
  assert.strictEqual(S.auditOf(s).run_seq, 1);
});
caseEnd();
