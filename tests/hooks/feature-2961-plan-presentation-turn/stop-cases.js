"use strict";
// #2961 Stop cases: the Stop guard asks for the plan-link line, writes the presentation receipt and
// continues only in a plan presentation turn (the stage's readiness is ready or unknown). A mid-turn
// (audit unsettled, or the plan rewritten so the settled run no longer matches) gets none of the three,
// on every gate value (ON / ERROR / OFF). unknown falls back to the legacy behaviour.
// Called from ../feature-2961-plan-presentation-turn-stop.js, which owns the case markers.
const assert = require("node:assert/strict");
const C = require("./common");

const { R, D, S, show } = C;
const PLAIN = "The outline is written; the pre-confirm audit runs next.";
const view = (st) => show({ rc: st.rc, blocked: st.blocked, continued: st.continued, reason: String(st.reason).slice(-400), err: String(st.err).slice(0, 200) });

// Every CONFIRM_* flag is pinned in the per-call .env root; ERROR comes from the probe-fault preload.
// CONV_LANG=english keeps the language directive off the block reason, so `continued` reads its head.
const LANG = { CONV_LANG: "english" };
const GATES = {
  ON: () => ({ cfg: R.cfg({ CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" }), env: LANG }),
  ERROR: () => ({ env: Object.assign({ CC_PROBE_FAULT: "exception", NODE_OPTIONS: R.nodeOptions([R.PRELOAD, R.PROBE_FAULT_PRELOAD]) }, LANG) }),
  OFF: () => ({ cfg: R.cfg({ CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "on" }), env: LANG }),
};
const stopOn = (gate, s, closing, stages) => R.stop(s.sid, R.presentTurn(s, stages || ["outline"], closing), GATES[gate]());

const NOT_LAST = (s) => "The outline is written.\n\n" + s.urlLine + "\n\nThe audit runs next.";
const unsettled = () => C.at("outline", { audit: false });
// Settled CONTINUE, then the plan rewritten: the settled run's ledger key no longer matches.
const rewritten = () => { const s = C.at("outline"); D.editPlan(s.sid, "outline", 61); return s; };

// A mid-turn: no plan-link block, no receipt, no continue, with or without the link line, with the
// line not closing the last text block (closeOnLinkReason's not-last branch), and after a rewrite.
function midTurn(gate) {
  const rows = [
    ["no link line", unsettled, () => PLAIN],
    ["link line", unsettled, (s) => "The outline is written.\n\n" + s.urlLine],
    ["link line not last", unsettled, NOT_LAST],
    ["rewritten after settle, no link line", rewritten, () => PLAIN],
    ["rewritten after settle, link line", rewritten, (s) => "The outline is rewritten.\n\n" + s.urlLine],
  ];
  for (const [label, make, close] of rows) {
    const s = make();
    const st = stopOn(gate, s, close(s));
    assert.ok(!st.blocked, `${gate} mid-turn (${label}): no block ${view(st)}`);
    assert.ok(!st.continued, `${gate} mid-turn (${label}): no continue ${view(st)}`);
    assert.ok(!R.receiptExists(s.sid, "outline"), `${gate} mid-turn (${label}): no receipt`);
  }
  if (gate === "OFF") return; // OFF owes the line once in the turn, so not-last does not apply
  // Control: the same not-last closing in a plan presentation turn is blocked as not-last.
  const p = C.at("outline");
  const ctl = stopOn(gate, p, NOT_LAST(p));
  assert.ok(ctl.blocked && ctl.reason.includes("(not-last)"), `${gate} plan presentation turn, link not last: not-last block ${view(ctl)}`);
}

// The plan presentation turn (audit settled CONTINUE) behaves as before.
function presentationTurn(gate) {
  const a = C.at("outline");
  const plain = stopOn(gate, a, PLAIN);
  const b = C.at("outline");
  const linked = stopOn(gate, b, "The outline is ready for review.\n\n" + b.urlLine);
  assert.ok(plain.blocked && !plain.continued, `${gate}: no link line -> block ${view(plain)}`);
  assert.ok(plain.reason.includes("[confirm-plan] plan-link:"), `${gate}: a plan-link reason ${view(plain)}`);
  if (gate === "OFF") {
    // OFF: the link line is still owed, but there is no approval dialog to continue into.
    assert.ok(!linked.blocked && !linked.continued, `OFF: link line -> no block, no continue ${view(linked)}`);
    return;
  }
  assert.ok(linked.continued, `${gate}: link line -> continue ${view(linked)}`);
  assert.ok(R.receiptExists(b.sid, "outline"), `${gate}: link line -> receipt`);
}

// Upstream: an approved intent rewritten unchanged owes nothing; changed, it follows its own readiness.
function upstreamIntent() {
  const same = C.at("outline");
  R.F.writePlan(same.sid, "intent");
  const st1 = stopOn("ON", same, "Intent refreshed; the outline comes next.", ["intent"]);
  assert.ok(!st1.blocked && !st1.continued, `unchanged approved intent: no duty ${view(st1)}`);
  assert.ok(!R.receiptExists(same.sid, "clarify_intent"), "unchanged approved intent: no receipt");
  const edited = C.at("outline");
  R.F.writePlan(edited.sid, "intent", R.EDITED_INTENT);
  const st2 = stopOn("ON", edited, "Intent updated; the audit runs next.", ["intent"]);
  assert.ok(!st2.blocked && !st2.continued, `edited intent, TR1 unsettled: mid-turn ${view(st2)}`);
  assert.ok(S.trySettle(edited.sid, "intent", "CONTINUE"), "fixture: TR1 settled on the edited intent");
  const st3 = stopOn("ON", edited, "Intent updated.", ["intent"]);
  assert.ok(st3.blocked, `edited intent, TR1 settled: a plan presentation turn, block without the link ${view(st3)}`);
}

// unknown readiness keeps the legacy behaviour: the audit state makes no difference.
// The corrupt side runs on every gate and pins the legacy values: no link line -> plan-link block.
function unknownIsLegacy() {
  const pair = () => [C.at("outline", { audit: false }), C.at("outline")];
  for (const gate of Object.keys(GATES)) {
    const [m1, p1] = pair();
    C.corruptState(m1.sid);
    C.corruptState(p1.sid);
    for (const [label, s] of [["unsettled", m1], ["settled", p1]]) {
      const st = stopOn(gate, s, PLAIN);
      assert.ok(st.blocked && !st.continued, `${gate} corrupt state (${label}): legacy block ${view(st)}`);
      assert.ok(st.reason.includes("[confirm-plan] plan-link:"), `${gate} corrupt state (${label}): a plan-link reason ${view(st)}`);
    }
  }
  const [m2, p2] = pair();
  const throwOpts = { cfg: GATES.ON().cfg, env: Object.assign({ CC_ARTIFACT_KEY_THROW: "1", NODE_OPTIONS: R.nodeOptions([R.PRELOAD, D.PRELOAD]) }, LANG) };
  const b = [m2, p2].map((s) => R.stop(s.sid, R.presentTurn(s, ["outline"], PLAIN), throwOpts));
  assert.ok(b[0].blocked && b[1].blocked, `key throw: legacy block without the link ${view(b[0])} ${view(b[1])}`);
}

module.exports = { GATES, midTurn, presentationTurn, upstreamIntent, unknownIsLegacy };
