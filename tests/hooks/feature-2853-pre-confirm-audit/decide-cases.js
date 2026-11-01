"use strict";
// #2853 TL1 cases for decideAuditGate(row, action, deps): the pure audit branch of the gate, with
// judgeStage / armStage / acceptedOnError stubbed. Called from ../feature-2853-pre-confirm-audit.js,
// which owns the case markers. The result may be a GATE_ACTION string or an object with .action;
// both are read here, and every other field is searched as JSON text.
const path = require("path");
const D = require("./driver");

const GM = D.X.tryRequire("bin/workflow/lib/next-step/gate-mode.js");
const { rowFor } = require(path.join(D.ROOT, "hooks/workflow-state/plan-stage-table"));
const ROW = Object.assign({ step: "outline" }, rowFor("outline"));
const RUN = "run-0007";

function stubs(o) {
  const calls = { arm: 0, judge: 0, onError: 0 };
  const deps = {
    sid: "f2853-decide", step: "outline", ctx: { cwd: D.X.TDIR },
    judgeStage: (...a) => { calls.judge += 1; return typeof o.judge === "function" ? o.judge(...a) : o.judge; },
    armStage: (...a) => { calls.arm += 1; return typeof o.arm === "function" ? o.arm(...a) : (o.arm || { ok: true, audit_run_id: "run-0009", run_id: "run-0009" }); },
    acceptedOnError: (...a) => { calls.onError += 1; return typeof o.onError === "function" ? o.onError(...a) : (o.onError || { accepted: false, runId: null }); },
  };
  return { deps, calls };
}

// decide(action, o) -> {action, text, calls}; a missing export or a throw is reported as the action.
async function decide(action, o) {
  if (GM.__missing || typeof GM.decideAuditGate !== "function") {
    return { action: "MISSING:" + (GM.__missing || "no decideAuditGate export"), text: "", calls: {} };
  }
  const { deps, calls } = stubs(o);
  let r;
  try { r = await GM.decideAuditGate(ROW, action, deps); } catch (e) { return { action: "THROW:" + e.message, text: "", calls }; }
  if (typeof r === "string") return { action: r, text: r, calls };
  const obj = r || {};
  return { action: obj.action || obj.gateAction || "", text: D.show(obj), calls };
}

const boom = (what) => () => { throw new Error(`stub ${what} failed`); };
const settled = (state, verdict) => ({ state, runId: RUN, verdict, summary: `stub ${verdict} summary` });

// (k) judgeStage throws and no acceptance is recorded: audit-block, REASON pre-confirm-audit:error.
async function k(check) {
  for (const action of ["ask", "proceed"]) {
    const r = await decide(action, { judge: boom("judgeStage"), onError: { accepted: false, runId: RUN } });
    check(`(k) ${action}: judge throws, no acceptance -> audit-block`, r.action === "audit-block", r.action + " " + r.text);
    check(`(k) ${action}: REASON pre-confirm-audit:error`, r.text.includes("pre-confirm-audit:error"), r.text);
    check(`(k) ${action}: acceptance guidance names the stage's last run`, r.text.includes(D.ACCEPT_SENTINEL) && r.text.includes(RUN), r.text);
    check(`(k) ${action}: acceptedOnError consulted`, r.calls.onError === 1, D.show(r.calls));
  }
}

// (l) judgeStage throws but the stage's last run carries an acceptance: the original action.
async function l(check) {
  for (const action of ["ask", "proceed"]) {
    const r = await decide(action, { judge: boom("judgeStage"), onError: { accepted: true, runId: RUN } });
    check(`(l) ${action}: judge throws, accepted run -> ${action}`, r.action === action, r.action + " " + r.text);
  }
}

// (m) armStage throws (or acceptedOnError throws too): audit-block, never ask / proceed.
async function m(check) {
  const unsettled = { state: "unsettled", runId: null, verdict: null, summary: null };
  const r1 = await decide("ask", { judge: unsettled, arm: boom("armStage") });
  check("(m) arm throws -> audit-block", r1.action === "audit-block", r1.action + " " + r1.text);
  check("(m) arm throws -> REASON pre-confirm-audit:error", r1.text.includes("pre-confirm-audit:error"), r1.text);
  const r2 = await decide("proceed", { judge: boom("judgeStage"), onError: boom("acceptedOnError") });
  check("(m) judge and acceptedOnError throw -> audit-block", r2.action === "audit-block", r2.action + " " + r2.text);
}

// (n) every judgeStage state maps to its action; only unsettled arms.
async function n(check) {
  for (const action of ["ask", "proceed"]) {
    const c = await decide(action, { judge: settled("settled-continue", "CONTINUE") });
    check(`(n) ${action}: settled-continue keeps the action, arms nothing`, c.action === action && c.calls.arm === 0, c.action + " " + D.show(c.calls));
    const w = await decide(action, { judge: settled("settled-warn", "WARN") });
    check(`(n) ${action}: settled-warn keeps the action`, w.action === action, w.action);
    check(`(n) ${action}: settled-warn hint carries summary and run id`, w.text.includes("stub WARN summary") && w.text.includes(RUN), w.text);
    const b = await decide(action, { judge: settled("settled-block", "BLOCK") });
    check(`(n) ${action}: settled-block -> audit-block`, b.action === "audit-block" && b.calls.arm === 0, b.action + " " + D.show(b.calls));
    const a = await decide(action, { judge: settled("accepted", "BLOCK") });
    check(`(n) ${action}: accepted keeps the action`, a.action === action && a.calls.arm === 0, a.action);
    const u = await decide(action, { judge: { state: "unsettled", runId: null, verdict: null, summary: null } });
    check(`(n) ${action}: unsettled arms once -> audit-wait`, u.action === "audit-wait" && u.calls.arm === 1, u.action + " " + D.show(u.calls));
    const cap = await decide(action, { judge: settled("cap-reached", "BLOCK") });
    check(`(n) ${action}: cap-reached -> audit-block, arms nothing`, cap.action === "audit-block" && cap.calls.arm === 0, cap.action + " " + D.show(cap.calls));
    check(`(n) ${action}: cap-reached carries acceptance guidance`, cap.text.includes(D.ACCEPT_SENTINEL), cap.text);
  }
}

module.exports = { k, l, m, n };
