"use strict";
// #2873 T5 cases (D5): recordOnConfirm(ctx, deps) records the capped stage audit's acceptance after
// a CONFIRM Allow only when WORKFLOW_OFF is off, the stage's CONFIRM gate is not OFF, and the
// judgment is an acceptable cap (terminal WARN / CONTINUE). Every refusal is shown, never silent.
// Stubbed deps. Called from ../feature-2873-cap-confirm-acceptance.js, which owns the case markers.
const assert = require("node:assert");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const SID = "f2873-handler";
const STAGES = [
  { step: "clarify_intent", suffix: "intent", tr: "TR1", label: "CONFIRM_INTENT" },
  { step: "outline", suffix: "outline", tr: "TR2", label: "CONFIRM_OUTLINE" },
  { step: "detail", suffix: "detail", tr: "TR3", label: "CONFIRM_DETAIL" },
];
const RUN = "run-0042";
const capJudge = (verdict, lastTerminal) => ({ state: "cap-reached", runId: RUN, verdict, summary: `stub ${verdict}`, lastTerminal });

// Lazy: the module does not exist until the implementation lands.
function load() {
  const m = require(path.join(ROOT, "hooks/workflow-mark/confirm-cap-acceptance.js"));
  assert.strictEqual(typeof m.recordOnConfirm, "function", "recordOnConfirm is exported");
  return m;
}

// call(o) -> {msg, records, gateCalls}: one recordOnConfirm with stubbed deps.
async function call(o) {
  const row = o.row || STAGES[1];
  const records = [];
  const gateCalls = [];
  const msgs = [];
  const deps = {
    judgeStage: () => { if (o.judgeThrows) throw new Error("stub judge failed"); return o.judge || capJudge("WARN", true); },
    isWorkflowOff: () => o.off === true,
    planGateState: (stage) => { gateCalls.push(stage); if (o.gateThrows) throw new Error("stub gate failed"); return o.gate || "ON"; },
    record: (sid, opts) => { records.push({ sid, opts }); return o.record || { ok: true, code: "recorded", verdict: (o.judge || {}).verdict || "WARN", tr_ids: [row.tr] }; },
  };
  await load().recordOnConfirm({ sessionId: SID, step: row.step, summary: o.summary || "approve the plan as written",
    repoCwd: ROOT, pushMessage: (m) => msgs.push(String(m)) }, deps);
  return { msg: msgs.join("\n"), records, gateCalls };
}

async function acceptableCapRecords() {
  for (const row of STAGES) {
    for (const verdict of ["WARN", "CONTINUE"]) {
      const tag = `[${row.step} ${verdict}]`;
      const r = await call({ row, judge: capJudge(verdict, true) });
      assert.strictEqual(r.records.length, 1, `${tag} one record; ${r.msg}`);
      const { sid, opts } = r.records[0];
      assert.strictEqual(sid, SID, tag);
      assert.strictEqual(opts.step, row.step, `${tag} step ${JSON.stringify(opts)}`);
      assert.strictEqual(opts.runId, RUN, tag);
      assert.strictEqual(opts.actor, row.label, tag);
      assert.strictEqual(opts.reporter, "workflow-mark:confirm-cap-acceptance", tag);
      assert.ok(opts.reason.startsWith(`${row.label} Allow at the audit run cap: `) && opts.reason.length > 20, `${tag} reason ${opts.reason}`);
      assert.deepStrictEqual(r.gateCalls, [row.suffix], `${tag} planGateState asked with the stage suffix`);
      assert.ok(r.msg.includes(`accepted by the ${row.label} Allow`) && r.msg.includes(RUN) && r.msg.includes(`(${row.tr})`), `${tag} message ${r.msg}`);
    }
  }
}

async function reasonIsOneCappedLine() {
  const r = await call({ summary: "line one\nline two " + "x".repeat(500) });
  assert.strictEqual(r.records.length, 1, r.msg);
  const reason = r.records[0].opts.reason;
  assert.ok(!/[\r\n]/.test(reason), `no newline: ${JSON.stringify(reason)}`);
  const prefix = "CONFIRM_OUTLINE Allow at the audit run cap: ";
  assert.ok(reason.startsWith(prefix), reason);
  assert.ok(reason.length - prefix.length <= 200, `summary part ${reason.length - prefix.length} chars`);
}

async function refusedRecordIsShown() {
  const r = await call({ record: { ok: false, code: "write-failed", message: "failed to write the acceptance record." } });
  assert.ok(r.msg.includes("acceptance NOT recorded") && r.msg.includes("write-failed"), r.msg);
  assert.ok(r.msg.includes("approval itself is recorded"), r.msg);
}

async function throwingJudgeIsShown() {
  const r = await call({ judgeThrows: true });
  assert.strictEqual(r.records.length, 0);
  assert.ok(r.msg.includes("acceptance NOT recorded") && r.msg.includes("judge-failed") && r.msg.includes("approval itself is recorded"), r.msg);
}

async function offOrGateOffRecordsNothing() {
  for (const o of [{ off: true }, { gate: "OFF" }, { gateThrows: true }]) {
    const r = await call(o);
    assert.strictEqual(r.records.length, 0, `${JSON.stringify(o)} must not record; ${r.msg}`);
    assert.ok(!r.msg.includes("accepted by the"), `${JSON.stringify(o)} message ${r.msg}`);
  }
}

async function otherJudgmentsRecordNothing() {
  const judgments = [
    { state: "settled-warn", runId: RUN, verdict: "WARN", summary: "s" },
    { state: "accepted", runId: RUN, verdict: "WARN" },
    { state: "unsettled", runId: null, verdict: null },
    capJudge("BLOCK", true),
    capJudge(null, true),
    capJudge("WARN", false),
  ];
  for (const judge of judgments) {
    const r = await call({ judge });
    assert.strictEqual(r.records.length, 0, `${JSON.stringify(judge)} must not record; ${r.msg}`);
    assert.ok(!r.msg.includes("accepted by the"), `${JSON.stringify(judge)} message ${r.msg}`);
  }
}

module.exports = {
  acceptableCapRecords, reasonIsOneCappedLine, refusedRecordIsShown, throwingJudgeIsShown,
  offOrGateOffRecordsNothing, otherJudgmentsRecordNothing,
};
