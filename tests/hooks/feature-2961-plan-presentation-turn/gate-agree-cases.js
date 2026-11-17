"use strict";
// #2961 gate agreement: next-step --gate (a child) and stageReadiness (a child under the same env)
// read one classification. detail Step 3 moves runGate / auditBranch onto stageReadiness without
// changing a byte of the gate output; these rows pin that output (GATE_ACTION, REASON,
// GATE_AUDIT_RUN_ID) and check that stageReadiness's action / audit lead to the same output.
// Called from readiness-cases.js (gateAgrees, otherVerdicts, judgeThrows).
const path = require("path");
const assert = require("node:assert/strict");
const { spawnSync } = require("child_process");
const C = require("./common");

const { R, D, S, show } = C;
const FLAGS = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };
const APPR_PRELOAD = path.join(__dirname, "approval-verdict-preload.js");
const RS_PRELOAD = path.join(__dirname, "readstate-throw-preload.js");

// Child env extras. Every row's gate child and readiness child get the same extras.
const ENV = {
  keyThrow: () => ({ CC_ARTIFACT_KEY_THROW: "1", NODE_OPTIONS: R.nodeOptions([D.PRELOAD]) }),
  accThrow: () => ({ CC_ARTIFACT_KEY_THROW: "1", CC_READSTATE_THROW: "1", NODE_OPTIONS: R.nodeOptions([D.PRELOAD, RS_PRELOAD]) }),
  verdict: (v) => ({ CC_APPR_VERDICT: v, NODE_OPTIONS: R.nodeOptions([APPR_PRELOAD]) }),
};

// readChild(sid, extra) -> stageReadiness(sid, "outline", {gate: "ON"}) in a child, or {missing}.
function readChild(sid, extra) {
  const q = { root: C.ROOT, sid, step: "outline", gate: "ON" };
  const env = Object.assign(D.childEnv(FLAGS, extra), { F2961_READ: JSON.stringify(q) });
  const r = spawnSync(process.execPath, [path.join(__dirname, "readiness-driver.js")], { env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  try { return JSON.parse(r.stdout || ""); } catch (_) { return { missing: `driver exit ${r.status}: ${r.stdout} ${r.stderr}` }; }
}

// gateOf(r) -> the gate output stageReadiness's action / audit imply (decideAuditGate's mapping):
// {action, reason (REASON suffix, null when no audit is read), runId (true: some run, false: none, undefined: not judged)}.
function gateOf(r) {
  const a = r.audit;
  if (a === null) return { action: r.action, reason: null };
  if (a.skipped) return { action: r.action, reason: "pre-confirm-audit:skipped-workflow-off" };
  if (a.threw !== undefined) return { action: "audit-block", reason: "pre-confirm-audit:error" };
  if ("accError" in a) return { action: "audit-block", reason: "pre-confirm-audit:error", runId: false };
  if (a.judgeError !== undefined) {
    return a.acc && a.acc.accepted === true
      ? { action: r.action, reason: "pre-confirm-audit:error-accepted" }
      : { action: "audit-block", reason: "pre-confirm-audit:error", runId: Boolean(a.acc && a.acc.runId) };
  }
  const j = a.j || {};
  const reason = "pre-confirm-audit:" + j.state;
  if (["settled-continue", "settled-warn", "accepted"].includes(j.state)) return { action: r.action, reason };
  if (j.state === "unsettled") return { action: "audit-wait", reason };
  if (j.state === "cap-reached") {
    const ok = r.action === "ask" && j.lastTerminal === true && ["WARN", "CONTINUE"].includes(j.verdict);
    return { action: ok ? r.action : "audit-block", reason };
  }
  return { action: "audit-block", reason };
}

// agree(rows): row = {label, sid, extra, state, action, reason, runId}. The readiness children run
// first (an unsettled gate arms a run); the gate rows are asserted before any readiness result, so
// the pinned gate output is checked even while stageReadiness does not exist yet.
function agree(rows) {
  const got = rows.map((row) => readChild(row.sid, row.extra));
  const gates = rows.map((row) => D.gate(row.sid, FLAGS, row.extra));
  rows.forEach((row, i) => {
    const g = gates[i];
    const tag = `${row.label} gate: ${g.out || g.err}`;
    assert.equal(g.action, row.action, tag);
    if (row.reason) assert.ok(g.reason.endsWith(", " + row.reason), `${tag} (REASON ends with ${row.reason})`);
    else assert.ok(!g.reason.includes("pre-confirm-audit"), `${tag} (no audit REASON)`);
    if (row.runId === true) assert.ok(g.lines.GATE_AUDIT_RUN_ID, `${tag} (GATE_AUDIT_RUN_ID)`);
    if (row.runId === false) assert.ok(!("GATE_AUDIT_RUN_ID" in g.lines), `${tag} (no GATE_AUDIT_RUN_ID)`);
  });
  rows.forEach((row, i) => {
    const r = got[i];
    assert.ok(!r.missing, `${row.label}: hooks/lib/presentation-readiness.js stageReadiness is not there yet: ${r.missing}`);
    assert.equal(r.state, row.state, `${row.label} readiness: ${show(r)}`);
    const want = gateOf(r);
    assert.equal(want.action, gates[i].action, `${row.label}: readiness implies GATE_ACTION ${want.action}: ${show(r)}`);
    if (want.reason) assert.ok(gates[i].reason.endsWith(", " + want.reason), `${row.label}: readiness implies REASON ${want.reason}: ${show(r)}`);
    if (want.runId !== undefined) assert.equal(Boolean(gates[i].lines.GATE_AUDIT_RUN_ID), want.runId, `${row.label}: run id ${show(r)}`);
  });
}

const settledBlock = () => { const s = C.at("outline", { audit: false }); S.settle(s.sid, "outline", "BLOCK"); return s.sid; };
const acceptedBlock = () => { const s = C.at("outline", { audit: false }); D.accept(s.sid, S.settle(s.sid, "outline", "BLOCK")); return s.sid; };

// The approval and audit states the gate reaches with a real fixture.
function baseRows() {
  const off = C.at("outline", { audit: false });
  C.workflowOff(off.sid);
  return [
    { label: "unsettled", sid: C.at("outline", { audit: false }).sid, state: "not-ready", action: "audit-wait", reason: "pre-confirm-audit:unsettled", runId: true },
    { label: "settled", sid: C.at("outline").sid, state: "ready", action: "ask", reason: "pre-confirm-audit:settled-continue", runId: true },
    { label: "settled BLOCK", sid: settledBlock(), state: "not-ready", action: "audit-block", reason: "pre-confirm-audit:settled-block", runId: true },
    { label: "workflow-off", sid: off.sid, state: "ready", action: "ask", reason: "pre-confirm-audit:skipped-workflow-off", runId: false },
    { label: "approved", sid: C.at("outline", { approved: true }).sid, state: "approved", action: "proceed", reason: null, runId: false },
  ];
}

// Verdicts other than approved / unapproved: the gate asks and runs the audit; readiness is unknown.
function verdictRows() {
  return [
    { label: "verdict skipped", sid: C.at("outline").sid, extra: ENV.verdict("skipped"), state: "unknown", action: "ask", reason: "pre-confirm-audit:settled-continue", runId: true },
    { label: "verdict not-applicable", sid: C.at("outline").sid, extra: ENV.verdict("not-applicable"), state: "unknown", action: "ask", reason: "pre-confirm-audit:settled-continue", runId: true },
    { label: "verdict unknown", sid: settledBlock(), extra: ENV.verdict("unknown"), state: "unknown", action: "audit-block", reason: "pre-confirm-audit:settled-block", runId: true },
  ];
}

// judgeStage throws: acceptedOnError accepted / not accepted / throws (the runId-less auditError).
function throwRows() {
  return [
    { label: "judge throws, accepted", sid: acceptedBlock(), extra: ENV.keyThrow(), state: "ready", action: "ask", reason: "pre-confirm-audit:error-accepted" },
    { label: "judge throws, not accepted", sid: settledBlock(), extra: ENV.keyThrow(), state: "unknown", action: "audit-block", reason: "pre-confirm-audit:error", runId: true },
    { label: "judge and acceptedOnError throw", sid: settledBlock(), extra: ENV.accThrow(), state: "unknown", action: "audit-block", reason: "pre-confirm-audit:error", runId: false },
  ];
}

module.exports = { agree, baseRows, verdictRows, throwRows };
