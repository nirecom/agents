"use strict";
// #2729 Gap 5 repro (session 1d12371e, R2): the presentation turn's last text block ends with the
// intent link line followed by a question, gate ON, intent unapproved. Stop must block with the
// present-again reason ("not-last") and write no receipt. Under stop_hook_active the same input is
// not blocked, but a supervisor finding is recorded and still no receipt is written.
// Prints PASS|name / FAIL|name|detail lines.
const R = require("./fixture");
const { check, show } = R;

// presentAgain(reason, stage) -> whether a Stop reason asks to close again on the stage's link line.
const presentAgain = (reason, stage) => reason !== "" && !reason.startsWith("[confirm-plan] continue:") &&
  reason.includes("plan-link") && reason.includes(`--stage ${stage}`);

const closing = (s) => "Here is the intent.\n\n" + s.urlLine + "\n\nDoes this match what you want?";

const s = R.sessionAt("intent", { tag: 1012 });
const st = R.stop(s.sid, R.presentTurn(s, ["intent"], closing(s)));
check("R2 link line then a question: Stop blocks", st.blocked, show({ rc: st.rc, out: st.out }));
check("R2 the block reason is the present-again reason for intent", presentAgain(st.reason, "intent"), st.reason || st.out);
check("R2 no intent receipt is written", !R.receiptExists(s.sid, "intent"), show(R.readReceiptRaw(s.sid, "intent")));

const t = R.sessionAt("intent", { tag: 1013 });
const before = R.findings(t.sid).length;
const sa = R.stop(t.sid, R.presentTurn(t, ["intent"], closing(t)), { input: { stop_hook_active: true } });
check("R2 stop_hook_active: no block is emitted", sa.rc === 0 && sa.out.trim() === "", show({ rc: sa.rc, out: sa.out }));
check("R2 stop_hook_active: one supervisor finding is recorded", R.findings(t.sid).length === before + 1, show({ before, after: R.findings(t.sid) }));
check("R2 stop_hook_active: no intent receipt is written", !R.receiptExists(t.sid, "intent"), show(R.readReceiptRaw(t.sid, "intent")));
const e = R.echo(t.sid, "intent");
check("R2 stop_hook_active: the later echo is denied", e.denied, show({ rc: e.rc, json: e.json }));
