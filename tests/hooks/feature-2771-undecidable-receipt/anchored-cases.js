"use strict";
// Private cases of tests/hooks/feature-2771-undecidable-receipt.js on the anchored undecidable path when
// the real final message presents a stage the anchored text entry did not. Requires the caller's isolate() pins first.
const fs = require("fs");
const path = require("path");
const R = require("../feature-2729-presentation-receipt/fixture");
const { A, T } = R;
const {
  QUESTION, THINK, closing, turn, ustop, relinked, notice, names, silent, seedReceipts, snap, rawReceipts, jaBody, pinLang,
} = require("./helpers");

// astop: the turn wrote `wrote` (a marker each), its last text entry closes on `anchorClose` with only
// thinking after it (anchored), and the unflushed final message is `last`.
const astop = (s, wrote, anchorClose, last, o) => {
  const opt = o || {};
  return ustop(s, turn(s, wrote, [A("a-anchor", T(anchorClose)), THINK("a-think")]),
    Object.assign({}, opt, { input: Object.assign({ last_assistant_message: last }, opt.input || {}) }));
};
const noDecision = (st) => st.rc === 0 && !("decision" in st.json);
// atDetail(tag, over): outline approved, detail unapproved with its gate ON; the anchored text closes on outline's link.
const atDetail = (tag, over) => R.sessionAt("detail", Object.assign({ tag }, over || {}));
const outlineClose = (s) => closing(s, ["outline"]);
const unpublishedLine = (s, stage) => `${stage}: \`${R.linesFor(s.sid, stage).fwd}\` (no URL: not-published)`;

function r30(check) {
  {
    const s = atDetail(3001);
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])));
    check("r30 final-only detail: rc 0, stdout empty (no decision, no notice)", silent(st), { rc: st.rc, out: st.out });
    const rc = R.readReceiptRaw(s.sid, "detail");
    check("r30 final-only detail: the detail receipt is recorded with anchorUuid \"\" and a url link", rc !== null && rc.anchorUuid === "" && rc.link && rc.link.kind === "url", rc);
    check("r30 final-only detail: no outline receipt (approved, not presented)", !R.receiptExists(s.sid, "outline"), snap(s.sid));
    check("r30 final-only detail: the turn markers are spent", R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
    const e = R.echo(s.sid, "detail");
    check("r30 final-only detail: the echo after it reaches the dialog", e.dialog, e.json);
  }
  {
    // Mixed: intent edited after approval (unapproved) and outline unapproved; the anchored text presents
    // intent only, the final message presents intent and outline.
    const s = R.sessionAt("outline", { tag: 3011 });
    fs.writeFileSync(R.linesFor(s.sid, "intent").plan, R.EDITED_INTENT);
    const st = astop(s, ["intent", "outline"], closing(s, ["intent"]), relinked(closing(s, ["intent", "outline"])));
    check("r30 mixed: rc 0, stdout empty", silent(st), { rc: st.rc, out: st.out });
    const ri = R.readReceiptRaw(s.sid, "intent");
    check("r30 mixed: intent (in both) keeps the anchored entry's uuid", ri !== null && ri.anchorUuid === "a-anchor", ri);
    const ro = R.readReceiptRaw(s.sid, "outline");
    check("r30 mixed: outline (final message only) is recorded with anchorUuid \"\"", ro !== null && ro.anchorUuid === "" && ro.link && ro.link.kind === "url", ro);
  }
  {
    const s = atDetail(3021);
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])) + "\n\n" + QUESTION);
    check("r30 a sentence after detail's link line: rc 0, no decision", noDecision(st), { rc: st.rc, out: st.out });
    check("r30 a sentence after detail's link line: no detail receipt", !R.receiptExists(s.sid, "detail"), snap(s.sid));
    check("r30 a sentence after detail's link line: the notice names detail", names(notice(st), "detail"), { rc: st.rc, out: st.out });
  }
  {
    const s = atDetail(3031);
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])), { cfg: R.cfg({ CONFIRM_DETAIL: "off" }) });
    check("r30 detail gate OFF: rc 0, stdout empty", silent(st), { rc: st.rc, out: st.out });
    check("r30 detail gate OFF: no detail receipt", !R.receiptExists(s.sid, "detail"), snap(s.sid));
  }
  {
    const s = atDetail(3041);
    seedReceipts(s);
    const before = rawReceipts(s.sid);
    const st = astop(s, ["detail"], outlineClose(s), "Detail is ready.\n\n" + unpublishedLine(s, "detail"), { env: { CC_UNPUBLISHED_STAGE: "detail" } });
    const after = rawReceipts(s.sid);
    check("r30 final-only unpublished detail: rc 0, no decision", noDecision(st), { rc: st.rc, out: st.out });
    check("r30 final-only unpublished detail: every seeded receipt file is byte-equal", before.every((b, i) => b !== null && b === after[i]), { before, after });
    check("r30 final-only unpublished detail: the notice names detail", names(notice(st), "detail"), { rc: st.rc, out: st.out });
  }
  {
    const s = atDetail(3051, { body: jaBody("detail") });
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])), pinLang({}));
    check("r30 final-only PLAN_LANG-violating detail: rc 0, no decision", noDecision(st), { rc: st.rc, out: st.out });
    check("r30 final-only PLAN_LANG-violating detail: no detail receipt", !R.receiptExists(s.sid, "detail"), snap(s.sid));
    check("r30 final-only PLAN_LANG-violating detail: the notice names detail", names(notice(st), "detail"), { rc: st.rc, out: st.out });
    const s2 = atDetail(3052, { body: jaBody("detail") });
    seedReceipts(s2);
    const before = rawReceipts(s2.sid);
    const st2 = astop(s2, ["detail"], outlineClose(s2), relinked(closing(s2, ["detail"])), pinLang({}));
    const after = rawReceipts(s2.sid);
    check("r30 final-only PLAN_LANG-violating detail seeded: every seeded receipt file is byte-equal", before.every((b, i) => b !== null && b === after[i]), { before, after });
    check("r30 final-only PLAN_LANG-violating detail seeded: the notice names detail", names(notice(st2), "detail"), { rc: st2.rc, out: st2.out });
  }
  {
    const s = atDetail(3061);
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])), { input: { stop_hook_active: true } });
    check("r30 stop_hook_active final-only detail: rc 0, stdout empty", silent(st), { rc: st.rc, out: st.out });
    const rc = R.readReceiptRaw(s.sid, "detail");
    check("r30 stop_hook_active final-only detail: the receipt is recorded with anchorUuid \"\"", rc !== null && rc.anchorUuid === "", rc);
    check("r30 stop_hook_active: the turn marker is kept (peek only)", R.turnMarkersLeft(s.sid) > 0, "markers=0");
  }
  {
    // Intent final-only: intent edited after approval (unapproved), outline unapproved; the anchored text
    // presents outline only, the final message presents intent only. Only intent's marker is written.
    const s = R.sessionAt("outline", { tag: 3071 });
    fs.writeFileSync(R.linesFor(s.sid, "intent").plan, R.EDITED_INTENT);
    const st = astop(s, ["intent"], closing(s, ["outline"]), relinked(closing(s, ["intent"])));
    // outline has no marker and the final message does not name it, so it is not in mayHavePresented.
    check("r30 intent final-only: rc 0, stdout empty (no decision, no notice)", silent(st), { rc: st.rc, out: st.out });
    const ri = R.readReceiptRaw(s.sid, "intent");
    check("r30 intent final-only: the intent receipt is recorded with anchorUuid \"\" and a url link", ri !== null && ri.anchorUuid === "" && ri.link && ri.link.kind === "url", ri);
    check("r30 intent final-only: no outline receipt (anchored-only stays unrecorded)", !R.receiptExists(s.sid, "outline"), snap(s.sid));
    const e = R.echo(s.sid, "intent");
    check("r30 intent final-only: the echo after it reaches the dialog", e.dialog, e.json);
  }
  {
    const s = atDetail(3081);
    // A directory standing at the receipt path makes writeReceipt's final rename fail.
    const blocked = R.receiptPath(s.sid, "detail");
    fs.mkdirSync(blocked, { recursive: true });
    fs.writeFileSync(path.join(blocked, "occupant"), "x");
    const PR = require(path.join(R.ROOT, "hooks/lib/presentation-receipt"));
    const dp = R.linesFor(s.sid, "detail");
    const probe = PR.writeReceipt(s.sid, "detail", { absPath: dp.plan, link: { kind: "url", value: dp.url }, contentSha: "abc", anchorUuid: "a-probe" });
    check("r30 final-only write failure setup: a receipt write onto the occupied path fails", probe === false, "writeReceipt returned " + probe);
    const st = astop(s, ["detail"], outlineClose(s), relinked(closing(s, ["detail"])));
    check("r30 final-only write failure: rc 0, no decision", noDecision(st), { rc: st.rc, out: st.out });
    check("r30 final-only write failure: the notice names detail", names(notice(st), "detail"), { rc: st.rc, out: st.out });
    fs.rmSync(blocked, { recursive: true, force: true });
    check("r30 final-only write failure: no detail receipt", !R.receiptExists(s.sid, "detail"), snap(s.sid));
    const e = R.echo(s.sid, "detail");
    check("r30 final-only write failure: the echo after it is denied (no-receipt)", e.denied && !e.dialog && e.reason.includes("(no-receipt)"), e.reason || e.json);
  }
}

module.exports = { r30 };
