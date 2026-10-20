"use strict";
// #2729 Gap 5 across stages (codex round 3 C2, supervisor run-0003 point 2; R13). closeOnLinkReason
// judges EVERY stage whose link appears in the last text block, not only the turn's marker stages
// and the current step's stage. Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const R = require("./fixture");
const { check, show } = R;

const presentAgain = (reason, stage) => reason !== "" && !reason.startsWith("[confirm-plan] continue:") &&
  reason.includes("plan-link") && reason.includes(`--stage ${stage}`);
const QUESTION = "Shall I adjust anything before you confirm?";
const noReceipts = (sid) => ["intent", "outline", "detail"].every((st) => !R.receiptExists(sid, st));

// outlineWithEditedIntent(tag) -> a session at outline whose intent was edited after approval (unapproved).
function outlineWithEditedIntent(tag) {
  const s = R.sessionAt("outline", { tag });
  const intent = R.linesFor(s.sid, "intent");
  fs.writeFileSync(intent.plan, R.EDITED_INTENT);
  return Object.assign(s, { intent });
}

{
  // Step outline; the turn wrote intent and outline; intent link -> question -> outline link.
  const s = outlineWithEditedIntent(1301);
  const st = R.stop(s.sid, R.presentTurn(s, ["intent", "outline"], "Updated.\n\n" + s.intent.urlLine + "\n\n" + QUESTION + "\n\n" + s.urlLine));
  check("R13 intent link, question, outline link: Stop blocks", st.blocked && !st.continued, show({ rc: st.rc, out: st.out }));
  check("R13 the block names intent (not-last)", presentAgain(st.reason, "intent"), st.reason || st.out);
  check("R13 no receipt is written for any stage", noReceipts(s.sid), show([R.readReceiptRaw(s.sid, "intent"), R.readReceiptRaw(s.sid, "outline")]));
}
{
  // Control: step outline, the turn rewrote intent only; intent link followed by a question.
  const s = outlineWithEditedIntent(1302);
  const st = R.stop(s.sid, R.presentTurn(s, ["intent"], "Intent updated.\n\n" + s.intent.urlLine + "\n\n" + QUESTION));
  check("R13 control: marker intent only, link then question: Stop blocks for intent", st.blocked && presentAgain(st.reason, "intent"), show({ rc: st.rc, out: st.out }));
}
{
  // Spec update: intent is neither a marker stage nor the current step's stage. The turn wrote
  // outline only, and re-quotes the earlier unapproved intent link followed by prose.
  const s = outlineWithEditedIntent(1303);
  const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "Outline written. For reference:\n\n" + s.intent.urlLine + "\n\nThe intent above still needs your review.\n\n" + s.urlLine));
  check("R13 re-quoted unapproved intent (not a marker, not the current step) then prose: Stop blocks", st.blocked && !st.continued, show({ rc: st.rc, out: st.out }));
  check("R13 re-quoted intent: the block names intent (not-last)", presentAgain(st.reason, "intent"), st.reason || st.out);
  check("R13 re-quoted intent: no receipt is written", noReceipts(s.sid), show(R.readReceiptRaw(s.sid, "outline")));
}
{
  // Spec update, no write at all this turn: the re-quoted unapproved intent link followed by prose.
  const s = outlineWithEditedIntent(1304);
  const st = R.stop(s.sid, R.presentTurn(s, [], "As a reminder, the intent is here:\n\n" + s.intent.urlLine + "\n\n" + QUESTION));
  check("R13 no marker at all, re-quoted unapproved intent then prose: Stop blocks for intent", st.blocked && presentAgain(st.reason, "intent"), show({ rc: st.rc, out: st.out }));
}
{
  // Control: an APPROVED stage's link re-quoted before prose is not judged unapproved: no block for it.
  const s = R.sessionAt("outline", { tag: 1305 });
  const intent = R.linesFor(s.sid, "intent");
  const st = R.stop(s.sid, R.presentTurn(s, ["outline"], "The approved intent is " + intent.urlLine + " and the outline follows.\n\n" + s.urlLine));
  check("R13 control: an approved intent re-quoted before prose does not block", !st.blocked || st.continued, show({ rc: st.rc, out: st.out }));
}
{
  // The right close: the last text block ends with the intent and outline link lines only.
  const s = outlineWithEditedIntent(1306);
  const st = R.stop(s.sid, R.presentTurn(s, ["intent", "outline"], "Both plans are ready.\n\n" + s.intent.urlLine + "\n" + s.urlLine));
  check("R13 trailing intent + outline link lines: Stop does not block on a plan-link reason", !st.blocked || st.continued, show({ rc: st.rc, out: st.out }));
  check("R13 trailing link lines: the continuation names the current step's stage (outline)", st.continued && st.reason.includes("WORKFLOW_CONFIRM_OUTLINE") && !st.reason.includes("CONFIRM_INTENT"),st.reason || st.out);
  check("R13 trailing link lines: both receipts are written", R.receiptExists(s.sid, "intent") && R.receiptExists(s.sid, "outline"),
    show([R.readReceiptRaw(s.sid, "intent"), R.readReceiptRaw(s.sid, "outline")]));
}
