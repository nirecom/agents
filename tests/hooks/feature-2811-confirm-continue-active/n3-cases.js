"use strict";
// N3 cases (write failures) and the notice ordering: a receipt or mark write that fails is reported
// and never turns into a continue; a notice rides along with a continue. check(name, ok, detail) is
// the entry file's reporter.
const fs = require("fs");
const R = require("../feature-2729-presentation-receipt/fixture");
const H = require("./helpers");

// markFailure: (g) the mark write fails, nothing else does: no continue, nothing to notify.
function markFailure(check) {
  const s = R.sessionAt("outline", { tag: 8301 });
  const d = H.decidable(s, ["outline"]);
  const st = H.stopOf(s, d.tp, { last: d.close, pre: [H.MARK_FAULT], env: H.faultEnv("mark") });
  check("g: the mark write fails: no continue, exit 0, stdout empty", H.silent(st), { rc: st.rc, out: st.out });
  check("g: the receipt itself is recorded, without a mark", H.rcpt(s.sid, "outline") !== null && !H.marked(s.sid, "outline"), H.rcpt(s.sid, "outline"));
}

// receiptFailure: (m) the only stage's receipt write fails: notice, no continue.
function receiptFailure(check) {
  const s = R.sessionAt("outline", { tag: 8311 });
  const d = H.decidable(s, ["outline"]);
  const st = H.stopOf(s, d.tp, { last: d.close, pre: [H.MARK_FAULT], env: H.faultEnv("receipt", "outline") });
  check("m: the receipt write fails: exit 0, no decision", st.rc === 0 && H.noDecision(st), { rc: st.rc, out: st.out });
  check("m: the systemMessage notice names outline", H.names(H.sysMsg(st), "outline"), { rc: st.rc, out: st.out });
  check("m: no receipt is left", H.noReceipt(s.sid), H.snap(s.sid));
}

// staleReceiptFailure: (C2) a valid receipt exists, the re-presentation's receipt write fails: notice,
// the old receipt is discarded and the following CONFIRM echo does not reach the dialog.
function staleReceiptFailure(check) {
  const s = R.sessionAt("outline", { tag: 8331 });
  H.seedReceipts(s);
  const before = R.readReceiptRaw(s.sid, "outline");
  const d = H.decidable(s, ["outline"]);
  const st = H.stopOf(s, d.tp, { active: true, last: d.close, pre: [H.MARK_FAULT], env: H.faultEnv("receipt", "outline") });
  check("C2 precondition: a valid outline receipt existed before", before !== null, before);
  check("C2: the receipt write fails: exit 0, no decision", st.rc === 0 && H.noDecision(st), { rc: st.rc, out: st.out });
  check("C2: the systemMessage notice names outline", H.names(H.sysMsg(st), "outline"), { rc: st.rc, out: st.out });
  check("C2: the old receipt is discarded", !R.receiptExists(s.sid, "outline"), H.snap(s.sid));
  const e = R.echo(s.sid, "outline");
  check("C2: the following CONFIRM echo does not reach the dialog (denied)", e.denied && !e.dialog, { rc: e.rc, json: e.json });
}

// noticeWithContinue: (n) continue and notice together, (r) cap still notifies, (s) mark failure still notifies.
function noticeWithContinue(check) {
  const mk = (tag) => {
    const s = R.sessionAt("outline", { tag });
    fs.writeFileSync(R.linesFor(s.sid, "intent").plan, R.EDITED_INTENT);
    return s;
  };
  const failIntent = { pre: [H.MARK_FAULT], env: H.faultEnv("receipt", "intent") };

  const s = mk(8321);
  const d = H.decidable(s, ["intent", "outline"]);
  const n = H.stopOf(s, d.tp, Object.assign({ last: d.close }, failIntent));
  check("n: intent fails, outline (current) recorded: exit 2 continue for outline", H.isContinue(n, "outline"), { rc: n.rc, out: n.out });
  check("n: the same JSON carries a systemMessage naming intent only", H.names(H.sysMsg(n), "intent") && !H.names(H.sysMsg(n), "outline"), n.json);
  check("n: only the outline receipt exists, and it is marked", H.marked(s.sid, "outline") && !R.receiptExists(s.sid, "intent"), H.snap(s.sid));

  const r = H.stopOf(s, H.decidable(s, ["intent", "outline"]).tp, Object.assign({ active: true, last: d.close }, failIntent));
  check("r: the cap (mark already set) emits no continue: exit 0, no decision", r.rc === 0 && H.noDecision(r), { rc: r.rc, out: r.out });
  check("r: the cap still prints the systemMessage notice naming intent", H.names(H.sysMsg(r), "intent"), { rc: r.rc, out: r.out });

  const s2 = mk(8322);
  const d2 = H.decidable(s2, ["intent", "outline"]);
  const m = H.stopOf(s2, d2.tp, { last: d2.close, pre: [H.MARK_FAULT], env: H.faultEnv("mark,receipt", "intent") });
  check("s: the mark write fails: no continue, exit 0, no decision", m.rc === 0 && H.noDecision(m), { rc: m.rc, out: m.out });
  check("s: the mark failure still prints the systemMessage notice naming intent", H.names(H.sysMsg(m), "intent"), { rc: m.rc, out: m.out });
  check("s: the outline receipt is recorded without a mark", R.receiptExists(s2.sid, "outline") && !H.marked(s2.sid, "outline"), H.snap(s2.sid));
}

module.exports = { markFailure, receiptFailure, staleReceiptFailure, noticeWithContinue };
