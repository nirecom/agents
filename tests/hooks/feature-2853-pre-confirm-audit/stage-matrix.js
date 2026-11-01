"use strict";
// #2853 TR1-3 x CONFIRM_* ON/OFF table: on every plan stage the unaudited gate arms the stage's
// pre-confirm audit (audit-wait) whatever the flag, and once the run settles CONTINUE the gate
// answers the stage's original action. Called from ../feature-2853-pre-confirm-audit.js, which owns
// the case markers. CONFIRM_INTENT has no OFF waiver (plan-stage-table offWaivable:false), so its
// OFF row still settles to ask.
const D = require("./driver");

const ROWS = [
  { stage: "intent", step: "clarify_intent", tr: "TR1", flag: "CONFIRM_INTENT", value: "on", settled: "ask" },
  { stage: "intent", step: "clarify_intent", tr: "TR1", flag: "CONFIRM_INTENT", value: "off", settled: "ask" },
  { stage: "outline", step: "outline", tr: "TR2", flag: "CONFIRM_OUTLINE", value: "on", settled: "ask" },
  { stage: "outline", step: "outline", tr: "TR2", flag: "CONFIRM_OUTLINE", value: "off", settled: "proceed" },
  { stage: "detail", step: "detail", tr: "TR3", flag: "CONFIRM_DETAIL", value: "on", settled: "ask" },
  { stage: "detail", step: "detail", tr: "TR3", flag: "CONFIRM_DETAIL", value: "off", settled: "proceed" },
];

// Every CONFIRM_* flag is pinned on each call; only the row's own flag differs from "on".
function flagsFor(row) {
  return Object.assign({ CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" }, { [row.flag]: row.value });
}

function run(check) {
  for (const row of ROWS) {
    const tag = `[${row.step} ${row.flag}=${row.value}]`;
    const s = D.X.sessionAt(row.stage);
    const over = flagsFor(row);
    const w = D.gate(s.sid, over);
    check(`${tag} unaudited: audit-wait`, w.action === "audit-wait", w.out || w.err);
    check(`${tag} gate line reports the pinned flag`, w.lines["GATE_" + row.flag] === row.value.toUpperCase(), w.out);
    const runId = D.audit(s.sid).audit_run_id || "";
    const ent = D.runEntry(s.sid, runId) || {};
    check(`${tag} armed run is ${row.tr} with cause pre-confirm:${row.step}`,
      runId !== "" && (ent.tr_ids || []).includes(row.tr) && ent.cause === `pre-confirm:${row.step}`, D.show(ent));
    check(`${tag} GATE_AUDIT_RUN_ID names the armed run`, runId !== "" && w.lines.GATE_AUDIT_RUN_ID === runId, w.out);
    let fin = true;
    try { D.S.finalize(s.sid, runId, "CONTINUE"); } catch (e) { fin = e.message; }
    check(`${tag} fixture finalize CONTINUE accepted`, fin === true, fin);
    const g = D.gate(s.sid, over);
    check(`${tag} settled CONTINUE: ${row.settled}`, g.action === row.settled, g.out || g.err);
    check(`${tag} settled: GATE_AUDIT_VERDICT=CONTINUE`, g.lines.GATE_AUDIT_VERDICT === "CONTINUE", g.out);
    check(`${tag} settled: no second run armed`, D.audit(s.sid).audit_run_id === runId, D.show([runId, D.audit(s.sid).audit_run_id]));
  }
}

module.exports = { ROWS, run };
