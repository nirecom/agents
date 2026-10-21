"use strict";
// Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/audit-arm.js, hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-writer/audit-run.js, hooks/stop-l2-findings-display.js, hooks/workflow-gate/user-verified-audit.js
// Tags: TL2, hooks, supervisor, supervisor-guard, stop-hook, alert, audit, launch-shown, user-verification, scope:issue-specific
// #2698 change 3, across Stops: the launch instruction appears once per intervention window
// (Stop 1 bundled, Stops 2-3 inside the P<=1 window silent, Stop 4 released); the writer's
// markAuditLaunchShown matches on run-id; result display is not a launch; TR5 supersedes an unshown run.
// TL3 gap (what this test does NOT catch):
// - the main conversation actually dispatching the bundled agents in one turn
// Closest-to-action mitigation: every Stop runs the real hook on a fresh stdin payload.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const X = require("./feature-2698-supervisor/fixture");
const S = require("./feature-2698-supervisor/audit-scene");

const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = X.tmpRoot("seq");
after(() => { restore(); X.rmRoot(ROOT); });

const now = () => new Date().toISOString();
const dump = (r) => `status=${r.status} stdout=${r.stdout.slice(0, 600)} stderr=${r.stderr.slice(0, 300)}`;
const launched = (r) => r.status === 2 && S.hasLaunch(S.reasonOf(r));

// finalizeCurrent(s, verdict) — the audit agent finishing the run the last Stop armed.
function finalizeCurrent(s, verdict) {
  const a = S.auditOf(s);
  if (!a.audit_run_id || a.audit_phase !== "pending") return;
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: a.audit_run_id, verdict, verdict_summary: "fixture" });
}

caseBegin("four-stop-sequence-one-launch-per-window", "hooks/supervisor-guard.js");
test("alert Stop, P=0 Stop, P=1 Stop, P=2 Stop -> launch shown on [Stop 1, Stop 4] only", () => {
  const s = S.scene(ROOT, "seq4", { alert: { alert_phase: "pending", alert_armed_at: now(), alert_retry_count: 0 } });
  const seen = [];
  const r1 = S.guard(s, S.turns(S.PROMPTS[0]), "s1");
  seen.push(launched(r1));
  // The supervisor agent completes the alert review at LAST_RUN_AT with an error verdict.
  assert.strictEqual(S.writer(s.dir, "writeAlertState", s.sid, {
    alert_phase: "done", alert_armed_at: null, last_run_at: S.LAST_RUN_AT, cumulative_severity: "error",
  }), true);
  finalizeCurrent(s, "CONTINUE");
  const r2 = S.guard(s, S.turns(S.PROMPTS[0]), "s2");
  seen.push(launched(r2));
  S.completeWriteCode(s);
  const r3 = S.guard(s, S.turns(S.PROMPTS[1]), "s3");
  seen.push(launched(r3));
  const r4 = S.guard(s, S.turns(S.PROMPTS[2]), "s4");
  seen.push(launched(r4));
  assert.deepStrictEqual(seen, [true, false, false, true], `per-Stop launch visibility (last: ${dump(r4)})`);
  // Inside the window the Stop is fully silent: no block of any kind, no context either.
  for (const [n, r] of [["Stop 2", r2], ["Stop 3", r3]]) {
    assert.strictEqual(r.status, 0, `${n} exits 0 (${dump(r)})`);
    assert.strictEqual(r.stdout.trim(), "", `${n} writes nothing (${dump(r)})`);
  }
});
caseEnd();

caseBegin("mark-audit-launch-shown-run-id-match", "hooks/lib/supervisor-state-writer.js");
test("markAuditLaunchShown is exported and marks only the matching unshown run", () => {
  const s = S.scene(ROOT, "mark", {});
  S.armUnshown(s);
  const wrong = S.writer(s.dir, "markAuditLaunchShown", s.sid, "run-0099");
  assert.notDeepStrictEqual(wrong, { missingExport: "markAuditLaunchShown" }, "markAuditLaunchShown is exported");
  assert.strictEqual(wrong, false, "a different run-id is not marked");
  assert.strictEqual(S.auditOf(s).audit_dispatched_at, null, "no write on a run-id mismatch");
  assert.strictEqual(S.writer(s.dir, "markAuditLaunchShown", s.sid, "run-0001"), true);
  const at = S.auditOf(s).audit_dispatched_at;
  assert.strictEqual(typeof at, "string");
  assert.strictEqual(S.writer(s.dir, "markAuditLaunchShown", s.sid, "run-0001"), false, "an already-shown run is not re-marked");
  assert.strictEqual(S.auditOf(s).audit_dispatched_at, at);
});
test("armAuditRun launch_shown:true sets audit_dispatched_at in the arm commit", () => {
  const s = S.scene(ROOT, "armls", {});
  const key = S.stepKey(s.dir, s.sid, "clarify_intent");
  S.writer(s.dir, "armAuditRun", s.sid, {
    tr_ids: ["TR1"], sub_checks: ["intent-internal"], transitions: [key], launch_shown: true,
    cause: "step-complete:clarify_intent", cwd: s.dir, plans_dir: s.dir,
  });
  assert.strictEqual(typeof S.auditOf(s).audit_dispatched_at, "string");
});
caseEnd();

caseBegin("result-display-is-not-a-launch", "hooks/stop-l2-findings-display.js");
test("alert findings + audit WARN surface as context only; neither output carries a launch", () => {
  const s = S.scene(ROOT, "disp", { alert: {
    alert_phase: "done", last_run_at: S.LAST_RUN_AT, findings_surfaced_at: null,
    findings: [S.finding("warning", "fixture warning")],
  } });
  S.armUnshown(s);
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "WARN", verdict_summary: "audit-warn-summary-token" });
  const d = S.display(s, S.turns(S.PROMPTS[2]), "d");
  assert.strictEqual(d.status, 0, dump(d));
  const dctx = d.json && d.json.additionalContext;
  assert.ok(typeof dctx === "string" && dctx.includes("fixture warning"), `the display hook surfaces the alert finding (${dump(d)})`);
  assert.ok(!S.hasLaunch(d.stdout), "the findings display is not a launch instruction");
  const g = S.guard(s, S.turns(S.PROMPTS[2]), "g");
  assert.strictEqual(g.status, 0, dump(g));
  assert.ok(!(g.json && g.json.decision === "block"), "the WARN verdict surface does not block");
  const gctx = g.json && g.json.additionalContext;
  assert.ok(typeof gctx === "string" && gctx.includes("audit-warn-summary-token"), `the guard surfaces the audit WARN verdict (${dump(g)})`);
  assert.ok(!S.hasLaunch(g.stdout), "the WARN verdict surface is not a launch instruction");
});
caseEnd();

// tr5(s) -> the reason checkUserVerifiedAudit hands to blockFn (approve yields "APPROVE").
function tr5(s) {
  const out = X.nodeEval(s.dir, `
const m = require(${JSON.stringify(X.lib("hooks/workflow-gate/user-verified-audit.js"))});
let got = null;
m.checkUserVerifiedAudit(process.argv[2], process.argv[3], {
  approveFn: () => { got = "APPROVE"; }, blockFn: (r) => { got = r; },
});
process.stdout.write(JSON.stringify(got));`, [s.sid, s.dir]);
  return JSON.parse(out);
}

caseBegin("tr5-arm-supersedes-unshown-run", "hooks/workflow-gate/user-verified-audit.js");
test("an unshown run + USER_VERIFIED -> a new shown run with TR5 added; the unshown run is superseded", () => {
  const s = S.scene(ROOT, "tr5u", {});
  S.armUnshown(s);
  const reason = tr5(s);
  assert.strictEqual(typeof reason, "string");
  assert.ok(reason.includes("run-0002"), `the TR5 arm mints a new run (${reason})`);
  const a = S.auditOf(s);
  const fresh = S.ledgerEntry(a, "run-0002");
  assert.ok(fresh && fresh.tr_ids.includes("TR5"), JSON.stringify(fresh));
  const old = S.ledgerEntry(a, "run-0001");
  assert.ok(old && old.outcome === "superseded", JSON.stringify(old));
  assert.strictEqual(typeof a.audit_dispatched_at, "string", "the TR5 reason is itself the launch");
});
test("regression: a SHOWN pending run + USER_VERIFIED -> the same run-id, no new run", () => {
  const s = S.scene(ROOT, "tr5s", {});
  S.armUnshown(s);
  S.writer(s.dir, "writeAuditState", s.sid, { audit_dispatched_at: now() });
  const reason = tr5(s);
  assert.ok(typeof reason === "string" && reason.includes("run-0001"), String(reason));
  assert.strictEqual(S.auditOf(s).run_seq, 1);
});
caseEnd();
