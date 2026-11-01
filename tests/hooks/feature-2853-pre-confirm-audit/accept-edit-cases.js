"use strict";
// #2853 (r)(s): a BLOCK accepted below the run cap stands only on the plan it accepted. After an
// outline edit (new stageKey / trigger_key) the acceptance no longer carries, so the stage is
// unsettled again and the gate arms a new run. Called from ../feature-2853-pre-confirm-audit.js,
// which owns the case markers.
const D = require("./driver");

const { X, S } = D;
const PCA = X.tryRequire("hooks/lib/pre-confirm-audit");
const judge = (sid) => {
  if (PCA.__missing || typeof PCA.judgeStage !== "function") return { state: "MISSING:" + (PCA.__missing || "no judgeStage") };
  try { return PCA.judgeStage(sid, "outline", { cwd: X.TDIR }) || {}; } catch (e) { return { state: "THROW:" + e.message }; }
};

// acceptedBlock(tag, check) -> {sid, runB}: an outline session whose BLOCK run (below the cap) is accepted.
function acceptedBlock(tag, check) {
  const s = X.sessionAt("outline");
  const runB = S.settle(s.sid, "outline", "BLOCK");
  const acc = D.accept(s.sid, runB) || {};
  check(`${tag} fixture: acceptance of the BLOCK run recorded`, acc.ok === true, D.show(acc));
  check(`${tag} fixture: below the cap`, (D.countOf(s.sid, "TR2") || 0) < 3, D.show(D.audit(s.sid).audit_run_counts));
  return { sid: s.sid, runB };
}

// (r) judgeStage: accepted on the accepted plan, unsettled once the plan is edited.
function r(check) {
  const { sid, runB } = acceptedBlock("(r)", check);
  const pre = judge(sid);
  check("(r) control: before the edit, judgeStage accepted on the BLOCK run", pre.state === "accepted" && pre.runId === runB, D.show(pre));
  D.editPlan(sid, "outline", 21);
  const post = judge(sid);
  check("(r) after the edit: judgeStage unsettled, not accepted", post.state === "unsettled", D.show(post));
}

// (s) next-step --gate: ask on the accepted plan, audit-wait with a fresh run once the plan is edited.
function s(check) {
  const { sid, runB } = acceptedBlock("(s)", check);
  const pre = D.gate(sid);
  check("(s) control: before the edit, gate answers ask", pre.action === "ask", pre.out || pre.err);
  D.editPlan(sid, "outline", 22);
  const post = D.gate(sid);
  const runN = D.audit(sid).audit_run_id;
  check("(s) after the edit: GATE_ACTION=audit-wait", post.action === "audit-wait", post.out || post.err);
  check("(s) after the edit: a new run is armed, not the accepted one",
    Boolean(runN) && runN !== runB && post.lines.GATE_AUDIT_RUN_ID === runN, D.show([runB, runN, post.lines.GATE_AUDIT_RUN_ID]));
}

module.exports = { r, s };
