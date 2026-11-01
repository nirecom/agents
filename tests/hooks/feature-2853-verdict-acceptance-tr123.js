"use strict";
// Tests: hooks/lib/null-freshness/acceptance.js, hooks/lib/supervisor-block-override.js, hooks/workflow-mark/supervisor-block-override-handler.js, hooks/lib/supervisor-state-writer/audit-run.js
// Tags: TL2, scope:issue-specific, supervisor, audit, acceptance
// #2853 Step 6: WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED also accepts a TR1-3 verdict, and an unsettled
// TR1-3 run as UNSETTLED (the run is discarded and audit_phase returns to done). TR5 keeps refusing UNSETTLED.
// TL3 gap (what this test does NOT catch): the real permissions.ask dialog is not driven; (b) runs the
// real next-step --gate CLI on fixture state, not inside a live session.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2853a-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.CONFIRM_INTENT = "on";
process.env.CONFIRM_OUTLINE = "on";
process.env.CONFIRM_DETAIL = "on";
delete process.env.WORKFLOW_SESSION_ID;
process.on("exit", () => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { make, mod } = require("./feature-2709-approval-bypass-closure/fixture");
const show = (v) => JSON.stringify(v);
const F = make({ TMP, CFG, eq: assert.deepStrictEqual, ok: assert.ok, show });
const ACC = mod("hooks/lib/null-freshness/acceptance.js");
const SBO = mod("hooks/lib/supervisor-block-override.js");
const AR = mod("hooks/lib/supervisor-state-writer/audit-run.js");
const REASON = "reviewed with the user; the finding is a known false positive";

function stageRun(id, verdict, tr, key) {
  return Object.assign(F.terminalRun(id, verdict, tr), { cause: `pre-confirm:${tr}`, trigger_input_keys: { [tr]: key } });
}
function setPhase(sid, phase) {
  const p = F.writer.getStatePath(sid, { forWrite: true });
  const st = JSON.parse(fs.readFileSync(p, "utf8"));
  st.audit.audit_phase = phase;
  fs.writeFileSync(p, JSON.stringify(st));
}
function handlerMsg(sid, runId, reason) {
  const msgs = [];
  mod("hooks/workflow-mark/supervisor-block-override-handler.js").handle({
    cmd: `echo "<<${ACC.SENTINEL_NAME}: ${runId} ${reason}>>"`,
    sessionId: sid, pushMessage: (m) => msgs.push(String(m)), signalFatal: (m) => msgs.push(String(m)),
  });
  return msgs.join("\n");
}

caseBegin("tr2-block-acceptance-pins-the-tr2-key", "hooks/lib/supervisor-block-override.js");
test("(a) accepting a TR2 BLOCK records it with the TR2 trigger key", () => {
  const sid = F.nextSid("a");
  F.seedSup(sid, [stageRun("run-0011", "BLOCK", "TR2", "k-tr2-outline")]);
  const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: "run-0011", reason: REASON, actor: "tester" });
  assert.ok(r.ok, `acceptance refused: ${show(r)}`);
  const rec = F.overrides(sid).at(-1);
  assert.strictEqual(rec.verdict, "BLOCK");
  assert.strictEqual(rec.trigger_key, "k-tr2-outline", `trigger_key ${show(rec)}`);
});
caseEnd();

caseBegin("handler-message-names-the-run-and-its-triggers", "hooks/workflow-mark/supervisor-block-override-handler.js");
test("handler message reads: the audit verdict of <run-id> (<tr_ids>) accepted", () => {
  const sid = F.nextSid("msg");
  F.seedSup(sid, [stageRun("run-0012", "WARN", "TR2", "k-tr2")]);
  const msg = handlerMsg(sid, "run-0012", REASON);
  assert.ok(/recorded/.test(msg), `recorded; got ${show(msg)}`);
  assert.ok(msg.includes("the audit verdict of run-0012 (TR2) accepted"), `message shape; got ${show(msg)}`);
});
caseEnd();

caseBegin("frozen-tr3-run-accepted-as-unsettled-releases-the-gate", "hooks/lib/supervisor-block-override.js");
test("(b) accepting a frozen TR3 run records UNSETTLED, returns audit_phase to done and lets the stage pass", () => {
  const D = require("./feature-2853-pre-confirm-audit/driver");
  const sid = F.nextSid("b");
  for (const s of ["clarify_intent", "outline", "detail"]) F.PAF.ensurePlan(sid, s);
  // The session sits at detail (intent and outline approved), so `next-step --gate` judges the TR3 stage.
  D.X.F.writeState(sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "complete",
    detail: "pending" }, [{ step: "clarify_intent" }, { step: "outline" }]);
  const armed = AR.armAuditRun(sid, { tr_ids: ["TR3"], cause: "pre-confirm:detail", launch_shown: true });
  assert.ok(armed.ok, `arm failed: ${show(armed)}`);
  setPhase(sid, "frozen");
  const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: armed.audit_run_id, reason: REASON, actor: "tester" });
  assert.ok(r.ok, `unsettled acceptance refused: ${show(r)}`);
  const st = F.supState(sid);
  assert.strictEqual(st.audit.audit_phase, "done");
  assert.strictEqual(st.audit.ledger.find((e) => e.id === armed.audit_run_id).outcome, "discarded-stale");
  assert.strictEqual(F.overrides(sid).at(-1).verdict, "UNSETTLED");
  const PCA = mod("hooks/lib/pre-confirm-audit.js");
  const j = PCA.judgeStage(sid, "detail", { cwd: TMP, plans_dir: process.env.WORKFLOW_PLANS_DIR, plan_session_id: sid });
  assert.ok(["accepted", "settled-continue", "settled-warn"].includes(j.state), `judgeStage ${show(j)}`);
  const ledgerBefore = D.ledgerOf(sid).length;
  const countBefore = D.countOf(sid, "TR3");
  const g = D.gate(sid, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" });
  assert.ok(["ask", "proceed"].includes(g.action), `gate after UNSETTLED acceptance must be ask/proceed; got ${show(g.action)} ${g.out}${g.err}`);
  assert.ok(!["audit-wait", "audit-block"].includes(g.action), `gate still waits/blocks: ${g.out}`);
  assert.strictEqual(g.lines.GATE_AUDIT_RUN_ID, armed.audit_run_id, `GATE_AUDIT_RUN_ID stays the accepted run; ${g.out}`);
  assert.strictEqual(D.ledgerOf(sid).length, ledgerBefore, "the gate arms no new run after the acceptance");
  assert.strictEqual(D.audit(sid).audit_run_id, armed.audit_run_id, "audit_run_id is still the accepted run");
  assert.strictEqual(D.countOf(sid, "TR3"), countBefore, `audit_run_counts.TR3 unchanged; ${show(D.audit(sid).audit_run_counts)}`);
});
caseEnd();

caseBegin("short-reason-is-refused", "hooks/lib/supervisor-block-override.js");
test("(c) a reason under 20 characters is refused and writes nothing", () => {
  const sid = F.nextSid("c");
  F.seedSup(sid, [stageRun("run-0013", "BLOCK", "TR1", "k-tr1")]);
  const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: "run-0013", reason: "abcdefghij klmnopqr", actor: "tester" });
  assert.strictEqual(r.code, "reason-too-short");
  assert.deepStrictEqual(F.overrides(sid), []);
});
caseEnd();

caseBegin("unsettled-tr4-and-tr5-runs-are-not-accepted", "hooks/lib/supervisor-block-override.js");
test("(d) an unsettled TR4 or TR5 run is not accepted as UNSETTLED", () => {
  for (const tr of ["TR4", "TR5"]) {
    const sid = F.nextSid(`d${tr}`);
    const armed = AR.armAuditRun(sid, { tr_ids: [tr], cause: `step-complete:${tr}`, launch_shown: true });
    const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: armed.audit_run_id, reason: REASON, actor: "tester" });
    assert.strictEqual(r.ok, false, `${tr}: must refuse; got ${show(r)}`);
    assert.deepStrictEqual(F.overrides(sid), [], `${tr}: no record`);
    assert.strictEqual(F.supState(sid).audit.audit_phase, "pending", `${tr}: phase untouched`);
  }
});
caseEnd();

caseBegin("unsettled-record-never-releases-tr5", "hooks/lib/null-freshness/acceptance.js");
test("(e) an UNSETTLED record is dropped by every TR5 classifier", () => {
  assert.deepStrictEqual([...ACC.ACCEPTABLE_VERDICTS], ["WARN", "BLOCK"]);
  const rec = { run_id: "run-0021", verdict: "UNSETTLED", freshness_key: "fk", artifact_keys: {}, trigger_key: "k" };
  assert.strictEqual(ACC.normalizeAcceptance(rec), null);
  const cases = [
    { name: "tr5-block", run: { id: "run-0021", verdict: "BLOCK", freshness_key: "fk" } },
    { name: "tr5-unsettled", run: { id: "run-0021", verdict: "UNSETTLED", freshness_key: "fk" } },
    { name: "tr5-no-verdict", run: { id: "run-0021", verdict: null, freshness_key: "fk" } },
  ];
  for (const { name, run } of cases) {
    assert.strictEqual(ACC.findAcceptance([rec], run), null, `${name}: findAcceptance`);
    assert.strictEqual(ACC.acceptanceReleasesNonNull({ tr5Run: run, overrides: [rec], currentFk: "fk" }), false, `${name}: release`);
  }
});
caseEnd();

caseBegin("stage-acceptance-takes-warn-block-continue-and-unsettled", "hooks/lib/null-freshness/acceptance.js");
test("findStageAcceptance accepts WARN, BLOCK, CONTINUE and UNSETTLED for the named run only", () => {
  assert.strictEqual(typeof ACC.findStageAcceptance, "function", "findStageAcceptance is exported");
  const cases = [
    { name: "warn", verdict: "WARN", want: true },
    { name: "block", verdict: "BLOCK", want: true },
    { name: "unsettled", verdict: "UNSETTLED", want: true },
    { name: "continue", verdict: "CONTINUE", want: true },
  ];
  for (const { name, verdict, want } of cases) {
    const audit = { block_overrides: [{ run_id: "run-0031", verdict, trigger_key: "k-tr3" }],
      ledger: [{ id: "run-0031", tr_ids: ["TR3"], outcome: "terminal", verdict }] };
    assert.strictEqual(Boolean(ACC.findStageAcceptance(audit, "TR3", "run-0031")), want, `${name}: same run`);
    assert.strictEqual(Boolean(ACC.findStageAcceptance(audit, "TR3", "run-0032")), false, `${name}: other run`);
  }
  // A CONTINUE record does not stand for a run whose own verdict is WARN.
  const mismatch = { block_overrides: [{ run_id: "run-0031", verdict: "CONTINUE", trigger_key: "k-tr3" }],
    ledger: [{ id: "run-0031", tr_ids: ["TR3"], outcome: "terminal", verdict: "WARN" }] };
  assert.strictEqual(Boolean(ACC.findStageAcceptance(mismatch, "TR3", "run-0031")), false, "CONTINUE record on a WARN run");
});
caseEnd();

caseBegin("stage-continue-is-accepted-tr5-continue-is-not", "hooks/lib/supervisor-block-override.js");
test("a plan-stage CONTINUE last terminal run is recorded; a TR5 CONTINUE needs no acceptance", () => {
  const sid = F.nextSid("cont");
  F.seedSup(sid, [stageRun("run-0041", "CONTINUE", "TR2", "k-tr2-cont")]);
  const r = SBO.recordReviewedVerdictAcceptance(sid, { runId: "run-0041", reason: REASON, actor: "tester" });
  assert.ok(r.ok, `stage CONTINUE refused: ${show(r)}`);
  assert.strictEqual(F.overrides(sid).at(-1).verdict, "CONTINUE");
  assert.strictEqual(F.overrides(sid).at(-1).trigger_key, "k-tr2-cont");
  const sid5 = F.nextSid("cont5");
  F.seedSup(sid5, [F.terminalRun("run-0042", "CONTINUE", "TR5")]);
  const r5 = SBO.recordReviewedVerdictAcceptance(sid5, { runId: "run-0042", reason: REASON, actor: "tester" });
  assert.strictEqual(r5.code, "verdict-not-acceptable", show(r5));
  assert.ok(/needs no acceptance/.test(r5.message), `message: ${r5.message}`);
  assert.deepStrictEqual(F.overrides(sid5), []);
});
caseEnd();

caseBegin("stage-continue-record-never-releases-tr5", "hooks/lib/null-freshness/acceptance.js");
test("a plan-stage CONTINUE record is dropped by every TR5 classifier", () => {
  assert.deepStrictEqual([...ACC.ACCEPTABLE_VERDICTS], ["WARN", "BLOCK"], "TR5 set unchanged");
  const sid = F.nextSid("cont-tr5");
  F.seedSup(sid, [stageRun("run-0051", "CONTINUE", "TR2", "k-tr2")]);
  SBO.recordReviewedVerdictAcceptance(sid, { runId: "run-0051", reason: REASON, actor: "tester" });
  const real = F.overrides(sid).at(-1);
  const literal = { run_id: "run-0051", verdict: "CONTINUE", freshness_key: "fk", artifact_keys: {}, trigger_key: "k-tr2" };
  const tr5Run = { id: "run-0051", verdict: "CONTINUE", freshness_key: (real && real.freshness_key) || "fk" };
  for (const [name, rec] of [["literal", literal], ["recorded", real]]) {
    assert.ok(rec, `${name}: a CONTINUE record exists`);
    assert.strictEqual(ACC.normalizeAcceptance(rec), null, `${name}: normalizeAcceptance`);
    assert.strictEqual(ACC.findAcceptance([rec], tr5Run), null, `${name}: findAcceptance`);
    assert.strictEqual(ACC.acceptanceReleasesNonNull({ tr5Run, overrides: [rec], currentFk: tr5Run.freshness_key }), false, `${name}: release`);
  }
});
caseEnd();

caseBegin("release-unsettled-run-discards-and-settles", "hooks/lib/supervisor-state-writer/audit-run.js");
test("releaseUnsettledRun discards the run and sets audit_phase to done; a stale run id is a no-op", () => {
  assert.strictEqual(typeof AR.releaseUnsettledRun, "function", "releaseUnsettledRun is exported");
  const sid = F.nextSid("rel");
  const armed = AR.armAuditRun(sid, { tr_ids: ["TR2"], cause: "pre-confirm:outline", launch_shown: true });
  AR.releaseUnsettledRun(sid, "run-0099");
  assert.strictEqual(F.supState(sid).audit.audit_phase, "pending", "a run id that is not armed changes nothing");
  AR.releaseUnsettledRun(sid, armed.audit_run_id);
  const st = F.supState(sid);
  assert.strictEqual(st.audit.audit_phase, "done");
  assert.strictEqual(st.audit.ledger.find((e) => e.id === armed.audit_run_id).outcome, "discarded-stale");
});
caseEnd();
