"use strict";
// C1 case (end-to-end chain): block for a missing plan-link, the re-presentation under
// stop_hook_active=true continues once and marks the receipt, then the CONFIRM echo reaches the
// approval dialog and consumes the receipt. check(name, ok, detail) is the entry file's reporter.
const R = require("../feature-2729-presentation-receipt/fixture");
const H = require("./helpers");
const { A, T } = R;

// chain: one continuous flow per stage, every hop asserted.
function chain(check) {
  ["intent", "outline", "detail"].forEach((stage, i) => {
    const id = `C1-${stage}`;
    const cfg = R.cfg({ ["CONFIRM_" + stage.toUpperCase()]: "on" });
    const s = R.sessionAt(stage, { tag: 8400 + i });

    const bare = "Here is the plan, please take a look.";
    const st0 = H.stopOf(s, H.turn(s, [stage], [A("a-bare", T(bare))]), { last: bare, cfg });
    check(`${id} a: the first Stop is blocked (exit 2, not a continue) for the missing plan-link`, st0.rc === 2 && st0.blocked && !st0.continued, { rc: st0.rc, out: st0.out });
    check(`${id} a: the blocked turn records no receipt`, H.noReceipt(s.sid), H.snap(s.sid));

    const d = H.decidable(s, [stage]);
    const st1 = H.stopOf(s, d.tp, { active: true, last: d.close, cfg });
    check(`${id} b/c: the re-presentation Stop under stop_hook_active=true continues (exit 2, [confirm-plan] continue)`, H.isContinue(st1, stage), { rc: st1.rc, out: st1.out });
    check(`${id} c: the continue reason carries the [confirm-plan] continue: prefix`, st1.reason.startsWith("[confirm-plan] continue:"), st1.reason);
    check(`${id} c: the receipt is recorded with continuedAt`, H.rcpt(s.sid, stage) !== null && H.marked(s.sid, stage), H.rcpt(s.sid, stage));

    const e = R.echo(s.sid, stage, { cfg });
    check(`${id} d: the CONFIRM echo reaches the approval dialog (ask)`, e.dialog && !e.denied && !e.skipped, { rc: e.rc, json: e.json, err: e.err });
    check(`${id} d: the echo consumed the presentation receipt`, !R.receiptExists(s.sid, stage), H.snap(s.sid));

    const e2 = R.echo(s.sid, stage, { cfg });
    check(`${id} d: a second echo has no receipt left and is denied`, e2.denied && !e2.dialog, { rc: e2.rc, json: e2.json });
  });
}

module.exports = { chain };
