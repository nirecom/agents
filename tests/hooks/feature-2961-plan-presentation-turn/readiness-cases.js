"use strict";
// #2961 readiness cases: auditAdmits (hooks/lib/pre-confirm-audit.js) classifies a judged stage as
// admit / arm / close, and stageReadiness (hooks/lib/presentation-readiness.js) turns the approval
// verdict and that classification into the hooks' state (ready / not-ready / approved / unknown) and
// the gate's action / audit. ready and unknown make the turn a plan presentation turn.
// Called from ../feature-2961-plan-presentation-turn.js, which owns the case markers.
const path = require("path");
const assert = require("node:assert/strict");
const { spawnSync } = require("child_process");
const C = require("./common");
const G = require("./gate-agree-cases");

const { R, D, S, show } = C;
const PCA = () => C.mod("hooks/lib/pre-confirm-audit");
const readiness = (sid, step, gate) => C.need("hooks/lib/presentation-readiness.js", "stageReadiness")(sid, step, gate ? { gate } : undefined);

// auditAdmits(j, action) table: every judged state x both actions.
function admitsTable() {
  const admits = C.need("hooks/lib/pre-confirm-audit.js", "auditAdmits");
  const capOk = { state: "cap-reached", lastTerminal: true, verdict: "WARN" };
  const capBlock = { state: "cap-reached", lastTerminal: true, verdict: "BLOCK" };
  const capOpen = { state: "cap-reached", lastTerminal: false, verdict: "WARN" };
  const rows = [
    [{ state: "settled-continue" }, "ask", "admit"], [{ state: "settled-continue" }, "proceed", "admit"],
    [{ state: "settled-warn" }, "ask", "admit"], [{ state: "settled-warn" }, "proceed", "admit"],
    [{ state: "accepted" }, "ask", "admit"], [{ state: "accepted" }, "proceed", "admit"],
    [{ state: "settled-block" }, "ask", "close"], [{ state: "settled-block" }, "proceed", "close"],
    [{ state: "unsettled" }, "ask", "arm"], [{ state: "unsettled" }, "proceed", "arm"],
    [capOk, "ask", "admit"], [capOk, "proceed", "close"],
    [capBlock, "ask", "close"], [capOpen, "ask", "close"],
    [{ state: "something-new" }, "ask", "close"], [{}, "ask", "close"],
  ];
  for (const [j, action, want] of rows) assert.equal(admits(j, action), want, `auditAdmits(${show(j)}, ${action})`);
}

// approved (not waived): no audit read, state approved, the gate proceeds.
function approvedNotWaived() {
  const s = C.at("outline", { approved: true, audit: false });
  const r = readiness(s.sid, "outline", "ON");
  assert.equal(r.state, "approved", show(r));
  assert.equal(r.action, "proceed", show(r));
  assert.equal(r.audit, null, show(r));
  assert.equal(r.appr && r.appr.verdict, "approved", show(r));
}

// waived (gate OFF on outline): the audit still decides; settled -> ready, unsettled -> not-ready.
function waivedFollowsAudit() {
  const settled = readiness(C.at("outline").sid, "outline", "OFF");
  assert.equal(settled.appr && settled.appr.waived, true, `fixture: the OFF gate waives: ${show(settled)}`);
  assert.equal(settled.action, "proceed", show(settled));
  assert.equal(settled.state, "ready", show(settled));
  assert.ok(settled.audit && settled.audit.j && settled.audit.j.state === "settled-continue", show(settled));
  const open = readiness(C.at("outline", { audit: false }).sid, "outline", "OFF");
  assert.equal(open.state, "not-ready", show(open));
  assert.equal(open.action, "proceed", show(open));
}

// unapproved x each judged state on the ON gate (action ask).
function unapprovedByAuditState() {
  const cases = [
    ["settled-continue", (sid) => S.settle(sid, "outline", "CONTINUE"), "ready"],
    ["settled-warn", (sid) => S.settle(sid, "outline", "WARN"), "ready"],
    ["settled-block", (sid) => S.settle(sid, "outline", "BLOCK"), "not-ready"],
    ["accepted", (sid) => D.accept(sid, S.settle(sid, "outline", "BLOCK")), "ready"],
    ["unsettled", () => null, "not-ready"],
  ];
  for (const [label, seed, want] of cases) {
    const s = C.at("outline", { audit: false });
    seed(s.sid);
    const r = readiness(s.sid, "outline", "ON");
    assert.equal(r.appr && r.appr.verdict, "unapproved", `${label} fixture: ${show(r)}`);
    assert.equal(r.action, "ask", `${label}: ${show(r)}`);
    assert.equal(r.audit && r.audit.j && r.audit.j.state, label, `${label}: ${show(r)}`);
    assert.equal(r.state, want, `${label}: ${show(r)}`);
  }
}

// capFixture(verdict) -> sid of an outline session past the TR2 run cap, the plan edited after each run.
function capFixture(verdict) {
  const s = C.at("outline", { audit: false });
  for (let i = 1; i <= 3; i += 1) {
    const a = PCA().armStage(s.sid, "outline", { cwd: R.TDIR }) || {};
    if (a.ok !== true || !a.audit_run_id) throw new Error(`fixture arm ${i} refused: ${show(a)}`);
    S.finalize(s.sid, a.audit_run_id, verdict);
    D.editPlan(s.sid, "outline", 30 + i);
  }
  return s.sid;
}

// cap-reached: ask admits a terminal WARN / CONTINUE, proceed (waiver) does not; BLOCK never;
// an acceptance past the cap stands on any plan.
function capReached() {
  for (const v of ["WARN", "CONTINUE"]) {
    const sid = capFixture(v);
    const ask = readiness(sid, "outline", "ON");
    assert.equal(ask.audit && ask.audit.j && ask.audit.j.state, "cap-reached", `${v} fixture: ${show(ask)}`);
    assert.equal(ask.state, "ready", `${v} ask: ${show(ask)}`);
    const waived = readiness(sid, "outline", "OFF");
    assert.equal(waived.action, "proceed", `${v} waived: ${show(waived)}`);
    assert.equal(waived.state, "not-ready", `${v} waived: ${show(waived)}`);
  }
  const sid = capFixture("BLOCK");
  assert.equal(readiness(sid, "outline", "ON").state, "not-ready", "BLOCK past the cap");
  const last = (D.ledgerOf(sid).slice(-1)[0] || {}).id;
  assert.equal((D.accept(sid, last) || {}).ok, true, "fixture: accept past the cap");
  D.editPlan(sid, "outline", 40);
  const r = readiness(sid, "outline", "ON");
  assert.equal(r.audit && r.audit.j && r.audit.j.state, "accepted", show(r));
  assert.equal(r.state, "ready", show(r));
}

// WORKFLOW_OFF: the audit is skipped and the stage is ready.
function workflowOff() {
  const s = C.at("outline", { audit: false });
  C.workflowOff(s.sid);
  const r = readiness(s.sid, "outline", "ON");
  assert.deepEqual(r.audit, { skipped: "workflow-off" }, show(r));
  assert.equal(r.state, "ready", show(r));
  assert.equal(r.action, "ask", show(r));
}

// judgeStage throws: accepted on error -> ready, not accepted -> unknown, acceptedOnError throws -> unknown.
// The gate child's GATE_ACTION / REASON / GATE_AUDIT_RUN_ID are compared first (detail Step 3).
function judgeThrows() {
  G.agree(G.throwRows());
  const acc = C.at("outline", { audit: false });
  D.accept(acc.sid, S.settle(acc.sid, "outline", "BLOCK"));
  const a = C.withKeyThrow(() => readiness(acc.sid, "outline", "ON"));
  assert.ok(a.audit && a.audit.judgeError !== undefined && a.audit.acc && a.audit.acc.accepted === true, show(a));
  assert.equal(a.state, "ready", show(a));
  const no = C.at("outline", { audit: false });
  S.settle(no.sid, "outline", "BLOCK");
  const n = C.withKeyThrow(() => readiness(no.sid, "outline", "ON"));
  assert.ok(n.audit && n.audit.acc && n.audit.acc.accepted === false, show(n));
  assert.equal(n.state, "unknown", show(n));
  const t = C.withReadStateThrow(() => C.withKeyThrow(() => readiness(C.at("outline").sid, "outline", "ON")));
  assert.ok(t.audit && t.audit.accError !== undefined, show(t));
  assert.equal(t.state, "unknown", show(t));
  assert.equal(t.action, "ask", show(t));
}

// approval verdicts other than approved / unapproved: unknown, the gate still asks and the audit is read.
function otherVerdicts() {
  G.agree(G.verdictRows()); // the gate child on the same verdict first (detail Step 3)
  const F = R.F;
  const skipped = C.at("outline");
  F.writeState(skipped.sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "skipped" }, [{ step: "clarify_intent" }]);
  const noState = R.uuidSid(9690);
  F.writePlan(noState, "intent");
  F.writePlan(noState, "outline");
  const corrupt = C.at("outline");
  C.corruptState(corrupt.sid);
  for (const [label, sid, verdict] of [["skipped", skipped.sid, "skipped"], ["no state file", noState, "not-applicable"], ["corrupt state", corrupt.sid, "unknown"]]) {
    const r = readiness(sid, "outline", "ON");
    assert.equal(r.appr && r.appr.verdict, verdict, `${label} fixture: ${show(r)}`);
    assert.equal(r.state, "unknown", `${label}: ${show(r)}`);
    assert.equal(r.action, "ask", `${label}: ${show(r)}`);
    assert.notEqual(r.audit, null, `${label}: the audit is still recorded: ${show(r)}`);
  }
}

// The gate (a child next-step --gate) and stageReadiness read one classification: the approval and
// audit states a real fixture reaches (gate-agree-cases.js owns the rows and the comparison).
function gateAgrees() {
  G.agree(G.baseRows());
}

// CONFIRM_INTENT=off: clarify_intent has no OFF waiver, so probesFor().gateFor reads ON and
// readinessFor judges on that ON (a child, so the .env root is the only CONFIRM_* source).
function intentOffReadsOn() {
  const settled = C.at("intent");
  const open = C.at("intent", { audit: false });
  const scene = { root: C.ROOT, sids: [settled.sid, open.sid] };
  const env = R.envFor({ cfg: R.cfg({ CONFIRM_INTENT: "off" }), env: { F2961_SCENE: JSON.stringify(scene) } });
  const r = spawnSync(process.execPath, [path.join(__dirname, "probes-driver.js")], { env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  let out = {};
  try { out = JSON.parse(r.stdout || "{}"); } catch (_) { out = { unparsed: r.stdout }; }
  assert.equal(r.status, 0, `driver exit ${r.status}: ${r.stderr}`);
  assert.equal(out.gate, "ON", show(out));
  assert.deepEqual(out.readiness, ["ready", "not-ready"], show(out));
}

module.exports = {
  admitsTable, approvedNotWaived, waivedFollowsAudit, unapprovedByAuditState, capReached,
  workflowOff, judgeThrows, otherVerdicts, gateAgrees, intentOffReadsOn,
};
