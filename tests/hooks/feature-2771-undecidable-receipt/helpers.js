"use strict";
// Private helpers of tests/hooks/feature-2771-undecidable-receipt.js: the undecidable Stop turn, the
// systemMessage notice reader and the receipt snapshots. Requires the caller's isolate() pins first.
const fs = require("fs");
const R = require("../feature-2729-presentation-receipt/fixture");
const { U, A, T, W, TR, BASH } = R;
const STAGES = ["intent", "outline", "detail"];

// A last_assistant_message the transcript never holds: readTurnTail waits, then reads undecidable.
const MISMATCH = "zz unflushed final message that this transcript does not hold";
const QUESTION = "Does this look right?";
const THINK = (uuid, type) => A(uuid, type === "redacted_thinking" ? { type, data: "x" } : { type: "thinking", thinking: "checking", signature: "sig" });
const STR = (uuid, text) => ({ type: "assistant", uuid, message: { role: "assistant", content: text } });
const closing = (s, stages) => "Here is the plan.\n\n" + stages.map((st) => R.linesFor(s.sid, st).urlLine).join("\n");

// turn(s, stages, tail, opts) -> transcript of one turn that wrote `stages` (a marker each unless
// opts.markers === false) and ends with the `tail` entries.
function turn(s, stages, tail, opts) {
  const o = opts || {};
  const entries = [U("write the plan", "u-prompt")];
  stages.forEach((st, i) => {
    const p = R.linesFor(s.sid, st).plan;
    if (o.markers !== false) R.turnMarker(s.sid, st, p);
    entries.push(A(`a-w${i}`, W(p, `w${i}`)), TR(`w${i}`, `u-tr${i}`));
  });
  return R.writeTranscript(s.sid, entries.concat(tail));
}
const ustop = (s, tp, opts) => {
  const o = opts || {};
  return R.stop(s.sid, tp, Object.assign({}, o, { input: Object.assign({ last_assistant_message: MISMATCH }, o.input || {}) }));
};
// relinked(close) -> a final message the transcript lacks (so still undecidable) that closes on close's link lines.
const relinked = (close) => "A different preface the transcript lacks.\n\n" + close.slice(close.indexOf("\n\n") + 2);
const linked = (close, input) => ({ input: Object.assign({ last_assistant_message: relinked(close) }, input || {}) });
// notice(st) -> the systemMessage when stdout is exactly one JSON object carrying it and no decision, else null.
function notice(st) {
  let j = null;
  try { j = JSON.parse(st.out.trim()); } catch (_) { return null; }
  if (st.rc !== 0 || !j || typeof j !== "object" || Array.isArray(j) || "decision" in j) return null;
  return typeof j.systemMessage === "string" && j.systemMessage.trim() !== "" ? j.systemMessage : null;
}
const names = (msg, stage) => typeof msg === "string" && new RegExp(`\\b${stage}\\b`, "i").test(msg);
const silent = (st) => st.rc === 0 && st.out.trim() === "";
const noReceipt = (sid) => STAGES.every((st) => !R.receiptExists(sid, st));
const appendTo = (p, text) => fs.writeFileSync(p, fs.readFileSync(p, "utf8") + text);
function seedReceipts(s) {
  for (const st of STAGES) {
    const p = R.linesFor(s.sid, st);
    if (!fs.existsSync(p.plan)) R.F.writePlan(s.sid, st);
    R.writeReceiptRaw(s.sid, st, { absPath: p.plan, link: { kind: "url", value: p.url }, contentSha: R.sha256(p.plan), anchorUuid: "a-old", writtenAt: new Date().toISOString() });
  }
}
// snap(sid) -> every stage's raw receipt; sameAs(before, sid) -> each one still there, byte-for-byte as seeded.
const snap = (sid) => STAGES.map((st) => R.readReceiptRaw(sid, st));
const sameAs = (before, sid) => {
  const after = snap(sid);
  return before.every((b, i) => b !== null && after[i] !== null && JSON.stringify(after[i]) === JSON.stringify(b));
};
// rawReceipts(sid) -> every stage's receipt file text (null when absent), for byte-equality checks.
const rawReceipts = (sid) => STAGES.map((st) => { try { return fs.readFileSync(R.receiptPath(sid, st), "utf8"); } catch (_) { return null; } });

// Japanese prose built from code points so the file stays ASCII-only; jaBody(stage) is the fixture's
// default plan with only its prose line swapped, so the headings stay canonical and only PLAN_LANG fails.
const JA = String.fromCharCode(0x3053, 0x306e, 0x8a08, 0x753b, 0x306f, 0x65e5, 0x672c, 0x8a9e, 0x3067, 0x66f8, 0x304b, 0x308c, 0x305f, 0x672c, 0x6587, 0x3067, 0x3059, 0x3002, 0x82f1, 0x8a9e, 0x3067, 0x306f, 0x3042, 0x308a, 0x307e, 0x305b, 0x3093, 0x3002);
const jaBody = (stage) => R.F.PLAN_BODY[stage].replace(/fixture (goal|approach|steps)/, JA);
// The parent's process.env may carry an ambient PLAN_LANG that outranks the fixture .env: pin it per call.
const pinLang = (o, lang) => Object.assign({ env: { PLAN_LANG: lang === undefined ? "english" : lang } }, o);
const MID = [A("a-mid", T("Checking the plan files once more.")), A("a-tool", BASH("ls", "b9"))];
// anchoredLangStop: link close then a thinking-only entry; d3bLangStop: the final text only in last_assistant_message.
const anchoredLangStop = (s, stage, input, turnOpts, lang) =>
  ustop(s, turn(s, [stage], [A("a-anchor", T(closing(s, [stage]))), THINK("a-think")], turnOpts), pinLang(linked(closing(s, [stage]), input), lang));
const d3bLangStop = (s, stage, lang) => ustop(s, turn(s, [stage], MID), pinLang({ input: { last_assistant_message: closing(s, [stage]) } }, lang));

module.exports = {
  STAGES, MISMATCH, QUESTION, THINK, STR, closing, turn, ustop, relinked, linked, notice, names, silent,
  noReceipt, appendTo, seedReceipts, snap, sameAs, rawReceipts, JA, jaBody, pinLang, anchoredLangStop, d3bLangStop, MID,
};
