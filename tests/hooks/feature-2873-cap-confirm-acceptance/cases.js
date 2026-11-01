"use strict";
// #2873 TL2 cases: a plan stage past its audit run cap (AUDIT_RUN_CAP = 3) whose plan was edited
// after the last run. Called from ../feature-2873-cap-confirm-acceptance.js, which owns the case
// markers. Each fixture is built once (real armStage / finalizeAuditRun writers, in process) and
// memoised, so a case that only reads never pays for the arm rounds again.
const fs = require("fs");
const path = require("path");
const assert = require("node:assert");
const D = require("../feature-2853-pre-confirm-audit/driver");

const ROOT = D.ROOT;
const STAGES = [
  { stage: "intent", step: "clarify_intent", tr: "TR1", label: "CONFIRM_INTENT" },
  { stage: "outline", step: "outline", tr: "TR2", label: "CONFIRM_OUTLINE" },
  { stage: "detail", step: "detail", tr: "TR3", label: "CONFIRM_DETAIL" },
];
const VERDICTS = ["WARN", "CONTINUE", "BLOCK"];
const OPEN = ["WARN", "CONTINUE"];
const REPORTER = "workflow-mark:confirm-cap-acceptance";
const CFG_BASE = path.join(path.dirname(process.env.WORKFLOW_STATE_DIR), "f2873-cfg");
const ALL_ON = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };
const ALL_OFF = { CONFIRM_INTENT: "off", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off" };

const mod = (rel) => require(path.join(ROOT, rel));
const PCA = () => mod("hooks/lib/pre-confirm-audit");
const show = D.show;
const has = (s, frag) => String(s).includes(frag);

const memo = new Map();
// capFixture(row, verdict, tag) -> {sid, stage, step, tr, label, verdict, lastRun}: three runs armed
// through PCA.armStage (the gate's arm path, counted), each finalized with verdict, the plan edited after each.
function capFixture(row, verdict, tag) {
  const key = `${row.stage}|${verdict}|${tag || ""}`;
  if (memo.has(key)) return memo.get(key);
  const s = D.X.sessionAt(row.stage);
  for (let i = 1; i <= 3; i += 1) {
    const a = PCA().armStage(s.sid, row.step, { cwd: D.X.TDIR }) || {};
    if (a.ok !== true || !a.audit_run_id) throw new Error(`fixture arm ${i} refused: ${show(a)}`);
    D.S.finalize(s.sid, a.audit_run_id, verdict);
    D.editPlan(s.sid, row.stage, 10 + i);
  }
  const lastRun = (D.ledgerOf(s.sid).slice(-1)[0] || {}).id;
  const fx = Object.assign({}, row, { sid: s.sid, verdict, lastRun });
  memo.set(key, fx);
  return fx;
}

// patchLastRun(sid, fields) -> rewrites the newest ledger entry in the supervisor state file.
function patchLastRun(sid, fields) {
  const p = mod("hooks/lib/supervisor-state-writer/shared").getStatePath(sid);
  const st = JSON.parse(fs.readFileSync(p, "utf8"));
  Object.assign(st.audit.ledger[st.audit.ledger.length - 1], fields);
  fs.writeFileSync(p, JSON.stringify(st));
}

function judge(fx) {
  try { return PCA().judgeStage(fx.sid, fx.step, { cwd: D.X.TDIR }) || {}; } catch (e) { return { state: "THROW:" + e.message }; }
}
function denyReason(fx) {
  return mod("hooks/confirm-checkpoint/pre-confirm-audit-deny").auditDenyReason(fx.sid, fx.stage);
}
const supState = (sid) => mod("hooks/lib/supervisor-state-writer").readState(sid) || {};
const overridesOf = (sid) => ((supState(sid).audit || {}).block_overrides) || [];
const findingsOf = (sid) => (((supState(sid).layer1 || {}).findings) || []).filter((f) => f && f.reporter === REPORTER);
const approvalOf = (sid, step) => ((mod("hooks/workflow-state").readState(sid) || {}).plan_approvals || {})[step] || null;

// allow(fx, flags) -> the pushed messages of one CONFIRM echo the user allowed (PostToolUse handler,
// in process), with the CONFIRM_* flags pinned through a fixture .env root.
function allow(fx, flags) {
  const CE = require("../../lib/confirm-env-fixture");
  const root = CE.confirmEnvRoot(CFG_BASE, flags || ALL_ON);
  const msgs = [];
  CE.withConfirmEnv(root, () => mod("hooks/workflow-mark/confirm-approval-handler").handle({
    cmd: D.X.echoOf(fx.stage), sessionId: fx.sid, repoCwd: D.X.TDIR,
    pushMessage: (m) => msgs.push(String(m)), signalFatal: (m) => msgs.push(String(m)),
  }));
  return msgs.join("\n");
}
const allowed = new Map();
function allowOnce(fx) {
  if (!allowed.has(fx)) allowed.set(fx, allow(fx));
  return allowed.get(fx);
}

function each(fn) {
  for (const row of STAGES) for (const v of VERDICTS) fn(capFixture(row, v), `[${row.step} ${v}]`);
}

// judgeStage at the cap carries the last run's verdict and whether it is terminal.
function judgeCarriesVerdict() {
  each((fx, tag) => {
    const j = judge(fx);
    assert.strictEqual(D.countOf(fx.sid, fx.tr), 3, `${tag} fixture: ${fx.tr} count is 3; ${show(D.audit(fx.sid).audit_run_counts)}`);
    assert.strictEqual(j.state, "cap-reached", `${tag} judgeStage ${show(j)}`);
    assert.strictEqual(j.runId, fx.lastRun, `${tag} runId is the stage's last run ${show(j)}`);
    assert.strictEqual(j.verdict, fx.verdict, `${tag} verdict ${show(j)}`);
    assert.strictEqual(j.lastTerminal, true, `${tag} lastTerminal ${show(j)}`);
    assert.strictEqual(typeof PCA().isCapConfirmAcceptable, "function", "isCapConfirmAcceptable is exported");
    assert.strictEqual(PCA().isCapConfirmAcceptable(j), OPEN.includes(fx.verdict), `${tag} isCapConfirmAcceptable`);
  });
}

// The gate asks for WARN / CONTINUE (summary on its own line) and keeps BLOCK on audit-block.
function gateAnswers() {
  each((fx, tag) => {
    const before = D.ledgerOf(fx.sid).length;
    const g = D.gate(fx.sid, ALL_ON);
    assert.ok(has(g.reason, "pre-confirm-audit:cap-reached"), `${tag} REASON ${g.reason} ${g.err}`);
    assert.strictEqual(D.ledgerOf(fx.sid).length, before, `${tag} no new run armed`);
    assert.strictEqual(g.lines.GATE_AUDIT_RUN_ID, fx.lastRun, `${tag} GATE_AUDIT_RUN_ID ${g.out}`);
    if (OPEN.includes(fx.verdict)) {
      assert.strictEqual(g.action, "ask", `${tag} action ${g.out} ${g.err}`);
      assert.strictEqual(g.lines.GATE_AUDIT_SUMMARY, `fixture ${fx.verdict} summary for ${fx.lastRun}`, `${tag} summary line ${g.out}`);
      assert.ok(has(g.hint, fx.lastRun) && has(g.hint, "Allow"), `${tag} hint names the run and the Allow ${g.hint}`);
      assert.ok(!has(g.hint, `fixture ${fx.verdict} summary`), `${tag} summary stays out of the hint ${g.hint}`);
    } else {
      assert.strictEqual(g.action, "audit-block", `${tag} action ${g.out} ${g.err}`);
      assert.ok(has(g.hint, D.ACCEPT_SENTINEL), `${tag} BLOCK keeps the VERDICT_ACCEPTED guidance ${g.hint}`);
    }
  });
}

// The CONFIRM deny opens for WARN / CONTINUE and stays closed on BLOCK.
function denyAnswers() {
  each((fx, tag) => {
    const r = denyReason(fx);
    if (OPEN.includes(fx.verdict)) assert.strictEqual(r, null, `${tag} deny must open; got ${r}`);
    else assert.ok(typeof r === "string" && has(r, "run cap") && has(r, D.ACCEPT_SENTINEL), `${tag} BLOCK deny ${r}`);
  });
}

// The Allow records one acceptance of the stage's last run (actor CONFIRM_<STAGE>) and one finding.
function allowRecords() {
  each((fx, tag) => {
    const msg = allowOnce(fx);
    assert.ok(approvalOf(fx.sid, fx.step), `${tag} the plan approval is recorded; ${msg}`);
    const recs = overridesOf(fx.sid);
    if (!OPEN.includes(fx.verdict)) {
      assert.deepStrictEqual(recs, [], `${tag} BLOCK records no acceptance`);
      assert.strictEqual(findingsOf(fx.sid).length, 0, `${tag} BLOCK leaves no finding`);
      assert.ok(!has(msg, "accepted by the CONFIRM"), `${tag} BLOCK message ${msg}`);
      return;
    }
    assert.strictEqual(recs.length, 1, `${tag} one acceptance; ${show(recs)} ${msg}`);
    assert.strictEqual(recs[0].run_id, fx.lastRun, `${tag} run_id ${show(recs[0])}`);
    assert.strictEqual(recs[0].verdict, fx.verdict, `${tag} verdict ${show(recs[0])}`);
    assert.strictEqual(recs[0].actor, fx.label, `${tag} actor ${show(recs[0])}`);
    assert.ok(typeof recs[0].reason === "string" && recs[0].reason.length > 20, `${tag} reason ${show(recs[0])}`);
    assert.strictEqual(findingsOf(fx.sid).length, 1, `${tag} one ${REPORTER} finding`);
    assert.ok(has(msg, `accepted by the ${fx.label} Allow`) && has(msg, fx.lastRun), `${tag} message ${msg}`);
  });
}

// D4: after the record, judgeStage reads accepted and the error exit (acceptedOnError) agrees.
function recordReleases() {
  each((fx, tag) => {
    allowOnce(fx);
    const j = judge(fx);
    const acc = PCA().acceptedOnError(fx.sid, fx.step) || {};
    const want = OPEN.includes(fx.verdict);
    assert.strictEqual(j.state, want ? "accepted" : "cap-reached", `${tag} judgeStage ${show(j)}`);
    assert.strictEqual(acc.accepted, want, `${tag} acceptedOnError ${show(acc)}`);
    assert.strictEqual(acc.runId, fx.lastRun, `${tag} acceptedOnError runId ${show(acc)}`);
  });
}

// A second Allow of the same CONFIRM adds no record and no finding.
function allowIsIdempotent() {
  each((fx, tag) => {
    allowOnce(fx);
    const want = OPEN.includes(fx.verdict) ? 1 : 0;
    const msg = allow(fx);
    assert.strictEqual(overridesOf(fx.sid).length, want, `${tag} still ${want} record(s) after the rerun; ${msg}`);
    assert.strictEqual(findingsOf(fx.sid).length, want, `${tag} still ${want} finding(s) after the rerun`);
    assert.ok(!has(msg, "NOT recorded"), `${tag} the rerun reports no refusal ${msg}`);
  });
}

// T2b: a last stage run without a verdict, or with a verdict but not terminal, stays closed in both
// the gate and the deny (they share one classification).
const NON_TERMINAL = [
  { name: "superseded-no-verdict", fields: { outcome: "superseded", verdict: null } },
  { name: "warn-not-terminal", fields: { outcome: "discarded-stale" } },
];
function nonTerminalFixture(row, v) {
  const key = `${row.stage}|nt|${v.name}`;
  if (memo.has(key)) return memo.get(key);
  const fx = capFixture(row, "WARN", "nt-" + v.name);
  patchLastRun(fx.sid, v.fields);
  memo.set(key, fx);
  return fx;
}
function nonTerminal(fn) {
  for (const row of STAGES) for (const v of NON_TERMINAL) fn(nonTerminalFixture(row, v), `[${row.step} ${v.name}]`);
}
function nonTerminalDeny() {
  nonTerminal((fx, tag) => {
    const j = judge(fx);
    assert.strictEqual(j.state, "cap-reached", `${tag} judgeStage ${show(j)}`);
    assert.notStrictEqual(j.lastTerminal, true, `${tag} lastTerminal ${show(j)}`);
    const r = denyReason(fx);
    assert.ok(typeof r === "string" && has(r, "run cap"), `${tag} deny stays closed; got ${r}`);
  });
}
function nonTerminalGate() {
  nonTerminal((fx, tag) => {
    const g = D.gate(fx.sid, ALL_ON);
    assert.strictEqual(g.action, "audit-block", `${tag} gate ${g.out} ${g.err}`);
    assert.ok(has(g.reason, "pre-confirm-audit:cap-reached"), `${tag} REASON ${g.reason}`);
  });
}

// D6: with the stage's CONFIRM gate OFF there is no Allow, so the gate stays audit-block (outline /
// detail) and the echo records no acceptance. intent has no OFF waiver, so it still asks and records.
const OFF_ROWS = [
  { row: STAGES[1], verdict: "WARN", gate: "audit-block", records: 0 },
  { row: STAGES[2], verdict: "CONTINUE", gate: "audit-block", records: 0 },
  { row: STAGES[0], verdict: "WARN", gate: "ask", records: 1 },
];
function confirmOffGate() {
  for (const o of OFF_ROWS) {
    const fx = capFixture(o.row, o.verdict, "off-gate");
    const g = D.gate(fx.sid, ALL_OFF);
    const tag = `[${fx.step} ${fx.verdict} OFF]`;
    assert.strictEqual(g.action, o.gate, `${tag} gate ${g.out} ${g.err}`);
    if (o.gate === "audit-block") assert.ok(has(g.hint, D.ACCEPT_SENTINEL), `${tag} VERDICT_ACCEPTED guidance ${g.hint}`);
  }
}
function confirmOffRecord() {
  for (const o of OFF_ROWS) {
    const fx = capFixture(o.row, o.verdict, "off-allow");
    const msg = allow(fx, ALL_OFF);
    const tag = `[${fx.step} ${fx.verdict} OFF]`;
    assert.ok(approvalOf(fx.sid, fx.step), `${tag} the plan approval is still recorded; ${msg}`);
    assert.strictEqual(overridesOf(fx.sid).length, o.records, `${tag} acceptance records ${show(overridesOf(fx.sid))} ${msg}`);
  }
}

// The real default deps: a WORKFLOW_OFF marker on the session keeps the Allow from recording, while
// the plan approval itself is still recorded (the gate skipped the audit, so the user saw no findings).
function workflowOffRecordsNothing() {
  const fx = capFixture(STAGES[1], "WARN", "wf-off");
  const { getSessionStateDir } = mod("hooks/workflow-state");
  fs.writeFileSync(path.join(getSessionStateDir(fx.sid), `${fx.sid}.workflow-off`), "fixture\n");
  const msg = allow(fx);
  assert.ok(approvalOf(fx.sid, fx.step), `the plan approval is recorded; ${msg}`);
  assert.deepStrictEqual(overridesOf(fx.sid), [], `WORKFLOW_OFF records no acceptance; ${msg}`);
  assert.ok(!has(msg, "accepted by the"), `message ${msg}`);
}

// A plan approval that fails to record leaves the acceptance unrecorded too: the Allow approves and
// accepts as one act, so half of it is never written. recordPlanApproval is made to throw for one call.
function approvalFailureRecordsNothing() {
  const fx = capFixture(STAGES[2], "WARN", "approval-fail");
  const CA = mod("hooks/workflow-state/completion-approval");
  const handlerPath = require.resolve(path.join(ROOT, "hooks/workflow-mark/confirm-approval-handler"));
  const original = CA.recordPlanApproval;
  let msg;
  try {
    CA.recordPlanApproval = () => { throw new Error("stub approval write failed"); };
    delete require.cache[handlerPath];
    msg = allow(fx);
  } finally {
    CA.recordPlanApproval = original;
    delete require.cache[handlerPath];
  }
  assert.ok(has(msg, "failed to record"), `the approval failure is reported; ${msg}`);
  assert.strictEqual(approvalOf(fx.sid, fx.step), null, "no plan approval recorded");
  assert.deepStrictEqual(overridesOf(fx.sid), [], `no acceptance recorded; ${msg}`);
  assert.strictEqual(findingsOf(fx.sid).length, 0, "no finding");
}

module.exports = {
  workflowOffRecordsNothing, approvalFailureRecordsNothing,
  judgeCarriesVerdict, gateAnswers, denyAnswers, allowRecords, recordReleases, allowIsIdempotent,
  nonTerminalDeny, nonTerminalGate, confirmOffGate, confirmOffRecord,
};
