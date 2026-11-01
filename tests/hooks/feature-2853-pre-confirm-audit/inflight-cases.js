"use strict";
// #2853 (t)(u): an armed run that is not yet settled (no verdict, no finalize) and still judges the
// current plan is reused. judgeStage reports it as unsettled + inFlight, and a rerun gate keeps
// answering audit-wait on the same run without arming or counting another one.
// Called from ../feature-2853-pre-confirm-audit.js, which owns the case markers.
const D = require("./driver");

const { X } = D;
const PCA = X.tryRequire("hooks/lib/pre-confirm-audit");
const judge = (sid) => {
  if (PCA.__missing || typeof PCA.judgeStage !== "function") return { state: "MISSING:" + (PCA.__missing || "no judgeStage") };
  try { return PCA.judgeStage(sid, "outline", { cwd: X.TDIR }) || {}; } catch (e) { return { state: "THROW:" + e.message }; }
};

// armedOutline(tag, check) -> {sid, runId}: an outline session whose TR2 run is armed and left unsettled.
function armedOutline(tag, check) {
  const s = X.sessionAt("outline");
  const g = D.gate(s.sid);
  const runId = D.audit(s.sid).audit_run_id || "";
  check(`${tag} fixture: the first gate arms a run`, g.action === "audit-wait" && runId !== "" && g.lines.GATE_AUDIT_RUN_ID === runId,
    g.out || g.err);
  return { sid: s.sid, runId };
}

// (t) judgeStage: unsettled, flagged inFlight, naming the armed run.
function t(check) {
  const { sid, runId } = armedOutline("(t)", check);
  const j = judge(sid);
  check("(t) judgeStage unsettled", j.state === "unsettled", D.show(j));
  check("(t) judgeStage inFlight on the armed run", j.inFlight === true && j.runId === runId, D.show(j));
}

// (u) next-step --gate three times: same run, no new ledger entry, TR2 counted once.
function u(check) {
  const { sid, runId } = armedOutline("(u)", check);
  const before = D.ledgerOf(sid).length;
  check("(u) fixture: TR2 counted once after the first arm", D.countOf(sid, "TR2") === 1, D.show(D.audit(sid).audit_run_counts));
  for (let i = 1; i <= 3; i += 1) {
    const g = D.gate(sid);
    check(`(u) rerun ${i}: GATE_ACTION=audit-wait`, g.action === "audit-wait", g.out || g.err);
    check(`(u) rerun ${i}: GATE_AUDIT_RUN_ID is the armed run`, g.lines.GATE_AUDIT_RUN_ID === runId, D.show([runId, g.lines.GATE_AUDIT_RUN_ID]));
    check(`(u) rerun ${i}: ledger length unchanged`, D.ledgerOf(sid).length === before, `${before} -> ${D.ledgerOf(sid).length}`);
    check(`(u) rerun ${i}: audit_run_counts.TR2 stays 1`, D.countOf(sid, "TR2") === 1, D.show(D.audit(sid).audit_run_counts));
  }
}

module.exports = { t, u };
