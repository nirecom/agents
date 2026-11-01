"use strict";
// Private cases of tests/hooks/feature-2771-undecidable-receipt.js on the undecidable no-anchor (D3b)
// path and the unpublished co-presented stage. Requires the caller's isolate() pins first.
const fs = require("fs");
const R = require("../feature-2729-presentation-receipt/fixture");
const { A, T } = R;
const {
  STAGES, QUESTION, THINK, closing, turn, ustop, linked, notice, names, silent, noReceipt, seedReceipts, snap, rawReceipts, MID,
} = require("./helpers");

// d3b: the final text never reached the transcript; its last text is mid-turn with a tool_use entry after it.
const d3b = (s, stages, last, o) =>
  ustop(s, turn(s, stages, MID, o), Object.assign({}, o, { input: Object.assign({ last_assistant_message: last }, (o && o.input) || {}) }));
const noDecision = (st) => st.rc === 0 && !("decision" in st.json);

function r23(check) {
  STAGES.forEach((stage, i) => {
    const s = R.sessionAt(stage, { tag: 2301 + i });
    const st = d3b(s, [stage], closing(s, [stage]));
    check(`r23 ${stage} marker, final text only in last_assistant_message: rc 0, stdout empty (no block, continue, notice)`, silent(st), { rc: st.rc, out: st.out });
    const rc = R.readReceiptRaw(s.sid, stage);
    check(`r23 ${stage}: the receipt is recorded with anchorUuid ""`, rc !== null && rc.anchorUuid === "" && rc.link && rc.link.kind === "url", rc);
    check(`r23 ${stage}: the turn markers are spent`, R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
    const e = R.echo(s.sid, stage);
    check(`r23 ${stage}: the echo after it reaches the dialog`, e.dialog, e.json);
  });
  const s1 = R.sessionAt("outline", { tag: 2311 });
  const st1 = d3b(s1, ["outline"], closing(s1, ["outline"]) + "\n\n" + QUESTION);
  check("r23 a sentence after the link line: no receipt, notice names outline, rc 0, no decision", noReceipt(s1.sid) && names(notice(st1), "outline"), { rc: st1.rc, out: st1.out, r: snap(s1.sid) });
  const s2 = R.sessionAt("outline", { tag: 2321 });
  const st2 = d3b(s2, ["outline"], closing(s2, ["outline"]), { markers: false });
  const rc2 = R.readReceiptRaw(s2.sid, "outline");
  check("r23 no marker, the link line names the plan file: outline receipt recorded with anchorUuid \"\", rc 0, stdout empty", silent(st2) && rc2 !== null && rc2.anchorUuid === "", { rc: st2.rc, out: st2.out, r: snap(s2.sid) });
  const e2 = R.echo(s2.sid, "outline");
  check("r23 no marker: the echo after it reaches the dialog", e2.dialog, e2.json);
  // Session at detail: outline is approved, detail is unapproved with its gate ON, so detail is judged too.
  const s3 = R.sessionAt("detail", { tag: 2331 });
  const st3 = d3b(s3, ["outline"], closing(s3, ["detail"]));
  check("r23 marker for outline, link line for detail: rc 0, no decision", noDecision(st3), { rc: st3.rc, out: st3.out });
  const rc3 = R.readReceiptRaw(s3.sid, "detail");
  check("r23 marker for outline, link line for detail: detail receipt recorded with anchorUuid \"\"", rc3 !== null && rc3.anchorUuid === "", snap(s3.sid));
  check("r23 marker for outline, link line for detail: no outline receipt", !R.receiptExists(s3.sid, "outline"), snap(s3.sid));
  const msg3 = notice(st3);
  check("r23 marker for outline, link line for detail: the notice names outline, not detail", names(msg3, "outline") && !names(msg3, "detail"), { rc: st3.rc, out: st3.out });
  const s4 = R.sessionAt("outline", { tag: 2341 });
  const st4 = d3b(s4, ["outline"], closing(s4, ["outline"]), { input: { stop_hook_active: true } });
  check("r23 stop_hook_active + marker: stdout empty, rc 0", silent(st4), { rc: st4.rc, out: st4.out });
  const rc4 = R.readReceiptRaw(s4.sid, "outline");
  check("r23 stop_hook_active + marker: the receipt is recorded with anchorUuid \"\"", rc4 !== null && rc4.anchorUuid === "", rc4);
  check("r23 stop_hook_active + marker: the turn marker is kept (peek only)", R.turnMarkersLeft(s4.sid) > 0, "markers=0");
}

function r28(check) {
  STAGES.forEach((stage, i) => {
    const s = R.sessionAt(stage, { tag: 2801 + i });
    const st = d3b(s, [stage], closing(s, [stage]), { markers: false });
    check(`r28 ${stage} no marker, D3b link close: rc 0, stdout empty`, silent(st), { rc: st.rc, out: st.out });
    const rc = R.readReceiptRaw(s.sid, stage);
    check(`r28 ${stage} no marker: the receipt is recorded with anchorUuid ""`, rc !== null && rc.anchorUuid === "" && rc.link && rc.link.kind === "url", rc);
    const e = R.echo(s.sid, stage);
    check(`r28 ${stage} no marker: the echo after it reaches the dialog`, e.dialog, e.json);

    const s1 = R.sessionAt(stage, { tag: 2811 + i });
    const st1 = d3b(s1, [stage], closing(s1, [stage]) + "\n\n" + QUESTION, { markers: false });
    check(`r28 ${stage} no marker, a sentence after the link line: no receipt, notice names ${stage}`, noReceipt(s1.sid) && names(notice(st1), stage), { rc: st1.rc, out: st1.out, r: snap(s1.sid) });

    const s2 = R.sessionAt(stage, { tag: 2821 + i, approved: true });
    const st2 = d3b(s2, [stage], closing(s2, [stage]), { markers: false });
    check(`r28 ${stage} no marker, stage approved: rc 0, no decision, no receipt`, noDecision(st2) && noReceipt(s2.sid), { rc: st2.rc, out: st2.out, r: snap(s2.sid) });

    // intent's gate cannot be waived (plan-gate.js: always ON), so the gate-OFF negative is outline/detail only.
    if (stage === "intent") return;
    const s3 = R.sessionAt(stage, { tag: 2831 + i });
    const cfg = R.cfg({ [`CONFIRM_${stage.toUpperCase()}`]: "off" });
    const st3 = d3b(s3, [stage], closing(s3, [stage]), { markers: false, cfg });
    check(`r28 ${stage} no marker, gate OFF: rc 0, stdout empty, no receipt`, silent(st3) && noReceipt(s3.sid), { rc: st3.rc, out: st3.out, r: snap(s3.sid) });
  });
  const s = R.sessionAt("outline", { tag: 2841 });
  const st = d3b(s, ["outline"], closing(s, ["outline"]), { markers: false, input: { stop_hook_active: true } });
  check("r28 stop_hook_active, no marker: rc 0, stdout empty", silent(st), { rc: st.rc, out: st.out });
  const rc = R.readReceiptRaw(s.sid, "outline");
  check("r28 stop_hook_active, no marker: the receipt is recorded with anchorUuid \"\" and nothing consumes it", rc !== null && rc.anchorUuid === "", rc);
  const e = R.echo(s.sid, "outline");
  check("r28 stop_hook_active, no marker: the echo after it reaches the dialog", e.dialog, e.json);
}

// r29 variants: [label, tag, run(s, close), anchorUuid the outline receipt is rewritten with].
const R29 = [
  ["anchored", 2901, (s, close, o) => ustop(s, turn(s, ["intent", "outline"], [A("a-anchor", T(close)), THINK("a-think")]), Object.assign(o, linked(close))), "a-anchor"],
  ["d3b", 2902, (s, close, o) => d3b(s, ["intent", "outline"], close, o), ""],
  ["d3b marker-less", 2903, (s, close, o) => d3b(s, ["intent", "outline"], close, Object.assign(o, { markers: false })), ""],
];

function r29(check) {
  for (const [label, tag, run, anchor] of R29) {
    // intent is edited after approval (unapproved) and left unpublished; outline is published and clean.
    const s = R.sessionAt("outline", { tag });
    const intent = R.linesFor(s.sid, "intent");
    fs.writeFileSync(intent.plan, R.EDITED_INTENT);
    seedReceipts(s);
    const before = rawReceipts(s.sid);
    const close = "Both plans are ready.\n\n" + `intent: \`${intent.fwd}\` (no URL: not-published)` + "\n" + s.urlLine;
    const st = run(s, close, { env: { CC_UNPUBLISHED_STAGE: "intent" } });
    const after = rawReceipts(s.sid);
    check(`r29 ${label}: rc 0, no decision`, noDecision(st), { rc: st.rc, out: st.out });
    check(`r29 ${label}: the unpublished intent's seeded receipt file is byte-equal (not discarded, not rewritten)`, before[0] !== null && after[0] === before[0], { before: before[0], after: after[0] });
    const rc = R.readReceiptRaw(s.sid, "outline");
    check(`r29 ${label}: the published outline's receipt is rewritten for this presentation (anchorUuid "${anchor}")`, rc !== null && rc.anchorUuid === anchor, rc);
    check(`r29 ${label}: the detail receipt not presented is byte-equal`, before[2] !== null && after[2] === before[2], { before: before[2], after: after[2] });
    const msg = notice(st);
    check(`r29 ${label}: the notice names intent only`, names(msg, "intent") && !names(msg, "outline"), { rc: st.rc, out: st.out });
  }
}

module.exports = { r23, r28, r29 };
