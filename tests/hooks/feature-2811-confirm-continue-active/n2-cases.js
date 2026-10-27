"use strict";
// N2 cases (undecidable tail): the final message (last_assistant_message) records the receipt and, only
// when the settle-time transcript re-read is flushed and its last assistant entry holds no tool_use,
// continues once. check(name, ok, detail) is the entry file's reporter.
const R = require("../feature-2729-presentation-receipt/fixture");
const H = require("./helpers");
const { A, T } = R;

// reread: (i) both/finalOnly positive, (o) re-read still unflushed, (p) re-read has tool_use.
function reread(check) {
  let tag = 8200;
  for (const kind of ["both", "finalOnly"]) {
    const s = R.sessionAt("outline", { tag: (tag += 1) });
    const run = H.rereadRun(s, ["outline"], kind, "flushed");
    const st = H.stopOf(s, run.tp, run.opts(false));
    check(`i ${kind}: undecidable tail, re-read flushed without tool_use: exit 2 with the continue reason`, H.isContinue(st, "outline"), { rc: st.rc, out: st.out });
    const rc = H.rcpt(s.sid, "outline");
    check(`i ${kind}: the receipt is recorded with the continuedAt mark`, rc !== null && H.marked(s.sid, "outline"), rc);
    check(`i ${kind}: the receipt anchor is ${kind === "both" ? "the text entry" : "empty (final message only)"}`, rc !== null && rc.anchorUuid === (kind === "both" ? "a-anchor" : ""), rc);
    const st2 = H.stopOf(s, run.tp, run.opts(true));
    check(`i ${kind}: the next active Stop is capped (exit 0, stdout empty)`, H.silent(st2), { rc: st2.rc, out: st2.out });
    check(`i ${kind}: the receipt is still marked after the capped Stop`, H.marked(s.sid, "outline"), H.rcpt(s.sid, "outline"));

    for (const variant of ["unflushed", "tooluse"]) {
      const s2 = R.sessionAt("outline", { tag: (tag += 1) });
      const r2 = H.rereadRun(s2, ["outline"], kind, variant);
      const st3 = H.stopOf(s2, r2.tp, r2.opts(false));
      const label = variant === "unflushed" ? "o: re-read still unflushed" : "p: re-read flushed but the last entry holds tool_use";
      check(`${label} (${kind}): no continue, exit 0, stdout empty`, H.silent(st3), { rc: st3.rc, out: st3.out });
      const rc2 = H.rcpt(s2.sid, "outline");
      check(`${label} (${kind}): the receipt is still recorded, without a mark`, rc2 !== null && !H.marked(s2.sid, "outline"), rc2);
    }
  }
}

// rereadTrailing: (q) text -> thinking-only continues (control); (r) text -> tool_use -> thinking-only must not.
function rereadTrailing(check) {
  let tag = 8300;
  for (const kind of ["both", "finalOnly"]) {
    const s = R.sessionAt("outline", { tag: (tag += 1) });
    const run = H.rereadRun(s, ["outline"], kind, "thinkonly");
    const st = H.stopOf(s, run.tp, run.opts(false));
    check(`q ${kind}: re-read text then thinking-only entry: exit 2 with the continue reason`, H.isContinue(st, "outline"), { rc: st.rc, out: st.out });
    check(`q ${kind}: the receipt is recorded and carries the continuedAt mark`, H.rcpt(s.sid, "outline") !== null && H.marked(s.sid, "outline"), H.rcpt(s.sid, "outline"));

    const sr = R.sessionAt("outline", { tag: (tag += 1) });
    const rr = H.rereadRun(sr, ["outline"], kind, "redacted");
    const str = H.stopOf(sr, rr.tp, rr.opts(false));
    check(`q ${kind}: re-read text then redacted_thinking-only entry: exit 2 with the continue reason`, H.isContinue(str, "outline"), { rc: str.rc, out: str.out });
    check(`q ${kind}: redacted_thinking: the receipt is recorded and carries the continuedAt mark`, H.rcpt(sr.sid, "outline") !== null && H.marked(sr.sid, "outline"), H.rcpt(sr.sid, "outline"));

    const s2 = R.sessionAt("outline", { tag: (tag += 1) });
    const r2 = H.rereadRun(s2, ["outline"], kind, "toolthink");
    const st2 = H.stopOf(s2, r2.tp, r2.opts(false));
    check(`r ${kind}: re-read text, tool_use entry, thinking-only entry: no continue (exit 0, no decision:block, no continue reason)`, st2.rc === 0 && H.noDecision(st2) && !st2.continued && !/\[confirm-plan\] continue/.test(st2.out || ""), { rc: st2.rc, out: st2.out });
    const rc2 = H.rcpt(s2.sid, "outline");
    check(`r ${kind}: the receipt is recorded without a continuedAt mark`, rc2 !== null && !H.marked(s2.sid, "outline"), rc2);
  }
}

// notContinued: (j) a stage the final message does not close on, (l) langBlocked and unpublished stages.
function notContinued(check) {
  const s = R.sessionAt("outline", { tag: 8251 });
  const close = H.closing(s, ["outline"]);
  const fresh = H.turn(s, ["outline"], [A("a-final", T(H.MISMATCH))]);
  const old = H.turn(s, ["outline"], [A("a-anchor", T(close)), H.THINK("a-think")]);
  const st = H.stopOf(s, old, { last: H.MISMATCH, pre: [H.REREAD], env: { CC_REREAD_OLD: old, CC_REREAD_NEW: fresh } });
  check("j: only the anchored text presents the stage, re-read flushed: no continue, no receipt", st.rc === 0 && H.noDecision(st) && H.noReceipt(s.sid), { rc: st.rc, out: st.out });
  check("j: the notice names outline", H.names(H.notice(st), "outline"), { rc: st.rc, out: st.out });

  const ja = R.sessionAt("outline", { tag: 8261, body: H.jaBody("outline") });
  const rl = H.rereadRun(ja, ["outline"], "both", "flushed");
  const stl = H.stopOf(ja, rl.tp, rl.opts(false));
  check("l: PLAN_LANG-violating stage, re-read flushed: no continue, no receipt", stl.rc === 0 && H.noDecision(stl) && H.noReceipt(ja.sid), { rc: stl.rc, out: stl.out });
  check("l: the notice names outline", H.names(H.notice(stl), "outline"), { rc: stl.rc, out: stl.out });

  const up = R.sessionAt("outline", { tag: 8271 });
  const line = `outline: \`${R.linesFor(up.sid, "outline").fwd}\` (no URL: not-published)`;
  const upMsg = "A different preface the transcript lacks.\n\n" + line;
  const upOld = H.turn(up, ["outline"], [A("a-anchor", T("Here is the plan.\n\n" + line))]);
  const upNew = H.turn(up, ["outline"], [A("a-final", T(upMsg))]);
  const stu = H.stopOf(up, upOld, { last: upMsg, pre: [H.REREAD], env: { CC_UNPUBLISHED_STAGE: "outline", CC_REREAD_OLD: upOld, CC_REREAD_NEW: upNew } });
  check("l: unpublished stage, re-read flushed: no continue, no receipt", stu.rc === 0 && H.noDecision(stu) && H.noReceipt(up.sid), { rc: stu.rc, out: stu.out });
  check("l: the notice names outline", H.names(H.notice(stu), "outline"), { rc: stu.rc, out: stu.out });
}

// otherStage: (k) the current stage failed to record, another stage did: notice only, no continue.
function otherStage(check) {
  const s = R.sessionAt("outline", { tag: 8281 });
  require("fs").writeFileSync(R.linesFor(s.sid, "intent").plan, R.EDITED_INTENT);
  const run = H.rereadRun(s, ["intent", "outline"], "both", "flushed");
  const st = H.stopOf(s, run.tp, run.opts(false, { pre: [H.MARK_FAULT], env: H.faultEnv("receipt", "outline") }));
  check("k: current stage (outline) fails to record, intent recorded: no continue, exit 0", st.rc === 0 && H.noDecision(st), { rc: st.rc, out: st.out });
  check("k: only intent has a receipt", R.receiptExists(s.sid, "intent") && !R.receiptExists(s.sid, "outline"), H.snap(s.sid));
  check("k: the notice names outline and not intent", H.names(H.notice(st), "outline") && !H.names(H.notice(st), "intent"), { rc: st.rc, out: st.out });
}

// rereadPerStage: (C1) the flushed re-read continue holds for every plan stage with its gate explicitly ON.
function rereadPerStage(check) {
  ["intent", "outline", "detail"].forEach((stage, i) => {
    const id = `N2-${stage}`;
    const cfg = R.cfg({ ["CONFIRM_" + stage.toUpperCase()]: "on" });
    const s = R.sessionAt(stage, { tag: 8290 + i });
    const run = H.rereadRun(s, [stage], "both", "flushed");
    const st = H.stopOf(s, run.tp, run.opts(false, { cfg }));
    check(`${id} a: undecidable tail, re-read flushed: first Stop continues (exit 2, [confirm-plan] continue: reason)`, st.rc === 2 && st.continued && H.isContinue(st, stage), { rc: st.rc, out: st.out });
    check(`${id} b: the ${stage} receipt carries continuedAt`, H.rcpt(s.sid, stage) !== null && H.marked(s.sid, stage), H.rcpt(s.sid, stage));
    const st2 = H.stopOf(s, run.tp, run.opts(true, { cfg }));
    check(`${id} c: second Stop does not continue (exit 0)`, st2.rc === 0 && !st2.continued, { rc: st2.rc, out: st2.out });
  });
}

module.exports = { reread, rereadTrailing,notContinued, otherStage, rereadPerStage };
