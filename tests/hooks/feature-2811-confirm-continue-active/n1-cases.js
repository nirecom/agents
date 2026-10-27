"use strict";
// N1 cases (decidable tail): a text-only presentation continues once under stop_hook_active=true,
// capped by the receipt's continuedAt mark. check(name, ok, detail) is the entry file's reporter.
const fs = require("fs");
const R = require("../feature-2729-presentation-receipt/fixture");
const H = require("./helpers");
const { A, T, show } = R;

// continueAndMark: (a) block records no receipt, (b)+(h) active continue marks and keeps the marker,
// plus the active=false control and the no-presentation / gate-OFF negative controls.
function continueAndMark(check) {
  const s = R.sessionAt("outline", { tag: 8101 });
  const bare = "Here is the plan, please take a look.";
  const st0 = H.stopOf(s, H.turn(s, ["outline"], [A("a-bare", T(bare))]), { last: bare });
  check("a: no plan-link line, active=false: block (exit 2), not a continue", st0.rc === 2 && st0.blocked && !st0.continued, { rc: st0.rc, out: st0.out });
  check("a: the blocked turn records no receipt", H.noReceipt(s.sid), H.snap(s.sid));

  const { close, tp } = H.decidable(s, ["outline"]);
  const st1 = H.stopOf(s, tp, { active: true, last: close });
  check("b: text-only presentation under stop_hook_active=true: exit 2 with the continue reason", H.isContinue(st1, "outline"), { rc: st1.rc, out: st1.out });
  check("b: the receipt is recorded and carries a continuedAt mark", H.rcpt(s.sid, "outline") !== null && H.marked(s.sid, "outline"), H.rcpt(s.sid, "outline"));
  check("h: active continue keeps the turn marker (not consumed)", R.turnMarkersLeft(s.sid) > 0, "markers=" + R.turnMarkersLeft(s.sid));

  const s2 = R.sessionAt("outline", { tag: 8102 });
  const d2 = H.decidable(s2, ["outline"]);
  const st2 = H.stopOf(s2, d2.tp, { last: d2.close });
  check("control: active=false presentation continues", H.isContinue(st2, "outline"), { rc: st2.rc, out: st2.out });
  check("control: the active=false continue also marks the receipt", H.marked(s2.sid, "outline"), H.rcpt(s2.sid, "outline"));
  check("h: active=false consumes the turn markers", R.turnMarkersLeft(s2.sid) === 0, "markers=" + R.turnMarkersLeft(s2.sid));

  const s3 = R.sessionAt("outline", { tag: 8103 });
  const st3 = H.stopOf(s3, H.turn(s3, ["outline"], [A("a-t", T("All done."))], { markers: false }), { active: true, last: "All done." });
  check("negative control: active with no presentation: exit 0, stdout empty, no receipt", H.silent(st3) && H.noReceipt(s3.sid), { rc: st3.rc, out: st3.out });

  const s4 = R.sessionAt("outline", { tag: 8104 });
  const d4 = H.decidable(s4, ["outline"]);
  const st4 = H.stopOf(s4, d4.tp, { active: true, last: d4.close, cfg: R.cfg({ CONFIRM_OUTLINE: "off" }) });
  check("classifier: CONFIRM_OUTLINE=off, active presentation: no continue, no receipt", H.silent(st4) && H.noReceipt(s4.sid), { rc: st4.rc, out: st4.out });
}

// limitAndCarry: (c) one continue per identical plan, (d) a changed plan re-arms, (f) a new user turn re-arms.
function limitAndCarry(check) {
  const s = R.sessionAt("outline", { tag: 8111 });
  const { close } = H.decidable(s, ["outline"]);
  const run = (active) => H.stopOf(s, H.turn(s, ["outline"], [A("a-anchor", T(close))]), { active, last: close });
  const first = run(true);
  const mark = H.rcpt(s.sid, "outline") && H.rcpt(s.sid, "outline").continuedAt;
  let continues = H.isContinue(first, "outline") ? 1 : 0;
  for (let i = 1; i <= 3; i++) {
    const st = run(true);
    if (st.rc === 2) continues += 1;
    check(`c: re-presentation #${i} of the same plan under active: exit 0, stdout empty`, H.silent(st), { rc: st.rc, out: st.out });
    const rc = H.rcpt(s.sid, "outline");
    check(`c: re-presentation #${i}: the receipt is rewritten and keeps the original continuedAt`, rc !== null && typeof mark === "string" && rc.continuedAt === mark, { mark, rc });
  }
  check("c: four active Stops over one plan continue exactly once", continues === 1, "continues=" + continues);

  fs.appendFileSync(s.plan, "\nedited after the first continue\n");
  const st = run(true);
  check("d: a changed plan (new contentSha) drops the mark: continues again", H.isContinue(st, "outline") && H.marked(s.sid, "outline"), { rc: st.rc, out: st.out });

  const s2 = R.sessionAt("outline", { tag: 8112 });
  const d2 = H.decidable(s2, ["outline"]);
  const a = H.stopOf(s2, d2.tp, { active: true, last: d2.close });
  const b = H.stopOf(s2, H.turn(s2, ["outline"], [A("a-anchor", T(d2.close))]), { active: false, last: d2.close });
  check("f: active continue, then a new user turn (active=false) with the same plan: continues again", H.isContinue(a, "outline") && H.isContinue(b, "outline"), { a: a.rc, b: b.rc, out: b.out });
  const c = H.stopOf(s2, H.turn(s2, ["outline"], [A("a-anchor", T(d2.close))]), { active: true, last: d2.close });
  check("f: the active=false continue left a fresh mark: the next active Stop is capped", H.silent(c), { rc: c.rc, out: c.out });
}

// activeBlock: (e) a block under stop_hook_active stays suppressed, keeps the receipt, leaves a notice.
function activeBlock(check) {
  const s = R.sessionAt("outline", { tag: 8121 });
  const p = R.linesFor(s.sid, "outline");
  const seeded = { absPath: p.plan, link: { kind: "url", value: p.url }, contentSha: R.sha256(p.plan), anchorUuid: "a-old", writtenAt: new Date().toISOString() };
  R.writeReceiptRaw(s.sid, "outline", seeded);
  const before = fs.readFileSync(R.receiptPath(s.sid, "outline"), "utf8");
  const last = H.closing(s, ["outline"]) + "\n\n" + H.QUESTION;
  const st = H.stopOf(s, H.turn(s, ["outline"], [A("a-anchor", T(last))]), { active: true, last });
  check("e: link line not closing the turn, active=true: exit 0, no block, stdout empty", H.silent(st), { rc: st.rc, out: st.out });
  check("e: the existing receipt is kept byte-for-byte", fs.readFileSync(R.receiptPath(s.sid, "outline"), "utf8") === before, show(H.rcpt(s.sid, "outline")));
  const notes = R.findings(s.sid).map((f) => show(f));
  check("e: recordUnblocked leaves a supervisor notice", notes.some((d) => d.includes("passed unblocked")), notes);
  check("e: the turn marker is kept (peek only)", R.turnMarkersLeft(s.sid) > 0, "markers=0");
}

// perStage: (C1) the stop_hook_active continue holds for every plan stage with its CONFIRM_<STAGE> gate
// explicitly ON: N1-<stage> continues once, marks the receipt, and the second Stop is capped.
function perStage(check) {
  ["intent", "outline", "detail"].forEach((stage, i) => {
    const id = `N1-${stage}`;
    const cfg = R.cfg({ ["CONFIRM_" + stage.toUpperCase()]: "on" });
    const s = R.sessionAt(stage, { tag: 8130 + i });
    const { close, tp } = H.decidable(s, [stage]);
    const st1 = H.stopOf(s, tp, { active: true, last: close, cfg });
    check(`${id} a: first active Stop continues (exit 2, [confirm-plan] continue: reason)`, st1.rc === 2 && st1.continued && H.isContinue(st1, stage), { rc: st1.rc, out: st1.out });
    check(`${id} b: the ${stage} receipt exists and carries continuedAt`, H.rcpt(s.sid, stage) !== null && H.marked(s.sid, stage), H.rcpt(s.sid, stage));
    const st2 = H.stopOf(s, tp, { active: true, last: close, cfg });
    check(`${id} c: second active Stop on the same transcript does not continue (exit 0)`, st2.rc === 0 && !st2.continued, { rc: st2.rc, out: st2.out });
  });
}

module.exports = { continueAndMark, limitAndCarry, activeBlock, perStage };
