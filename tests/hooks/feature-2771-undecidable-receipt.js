#!/usr/bin/env node
// tests/hooks/feature-2771-undecidable-receipt.js
// Tests: hooks/stop-confirm-plan-guard.js, hooks/stop-confirm-plan-guard/undecidable.js
// Tags: TL2, hooks, confirm-plan, stop-guard, presentation-receipt, transcript-reader, scope:issue-specific
// TL3 gap: whether the host shows a Stop hook's exit-0 systemMessage to the user, and the real
// conditions under which the final transcript line is not flushed at Stop; mitigated by
// bin/check-verification-gate.sh (category: hook-registration).
// #2771: a Stop whose tail is undecidable still records the receipt of a turn that closed on its
// link lines (never blocks, never continues), and tells the user, per stage, what it could not record.
"use strict";

const { after: afterAll, test } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2771-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.PLAN_LANG;
process.chdir(SCRATCH);
afterAll(() => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const R = require("./feature-2729-presentation-receipt/fixture");
const { U, A, T, BASH, TR, show } = R;
const {
  STAGES, MISMATCH, QUESTION, THINK, STR, closing, turn, ustop, linked, notice, names, silent,
  noReceipt, appendTo, seedReceipts, snap, sameAs, rawReceipts, jaBody, pinLang, anchoredLangStop, d3bLangStop,
} = require("./feature-2771-undecidable-receipt/helpers");
// r23 / r28 (the no-anchor path) and r29 (an unpublished co-presented stage) live in the module.
const D3B = require("./feature-2771-undecidable-receipt/d3b-cases");
// r30 (a stage only the final message presents, on the anchored path) lives in its own module.
const ANCH = require("./feature-2771-undecidable-receipt/anchored-cases");
const UNIT = require("./feature-2771-undecidable-receipt/unit-cases");

let failed = 0;
const failureCount = () => failed;
function check(name, ok, detail) {
  if (ok) { process.stdout.write(`PASS: ${name}\n`); return; }
  failed += 1;
  process.stdout.write(`FAIL: ${name} — ${typeof detail === "string" ? detail : show(detail)}\n`);
}

caseBegin("r16-undecidable-tail-records-receipt-every-stage", "hooks/stop-confirm-plan-guard.js");
test("r16-undecidable-tail-records-receipt-every-stage", () => noNewFailures(failureCount, () => {
STAGES.forEach((stage, i) => {
  const s = R.sessionAt(stage, { tag: 1600 + i });
  const st = ustop(s, turn(s, [stage], [A("a-anchor", T(closing(s, [stage]))), THINK("a-think")]), linked(closing(s, [stage])));
  check(`r16 ${stage}: undecidable, link close then a thinking-only entry: rc 0, no block, no continue, no notice`, silent(st), { rc: st.rc, out: st.out });
  const rc = R.readReceiptRaw(s.sid, stage);
  check(`r16 ${stage}: the receipt is recorded against the text entry`, rc !== null && rc.anchorUuid === "a-anchor" && rc.link && rc.link.kind === "url", rc);
  check(`r16 ${stage}: the turn markers are spent`, R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
  const e = R.echo(s.sid, stage);
  check(`r16 ${stage}: the echo after it reaches the dialog`, e.dialog, e.json);

  const s2 = R.sessionAt(stage, { tag: 1610 + i });
  ustop(s2, turn(s2, [stage], [A("a-anchor", T(closing(s2, [stage]))), THINK("a-think")]), linked(closing(s2, [stage])));
  appendTo(s2.plan, "\nedited after the presentation\n");
  const e2 = R.echo(s2.sid, stage);
  check(`r16 ${stage}: a plan edited after the undecidable record is denied (content)`, e2.denied && e2.reason.includes("(content)"), e2.reason || e2.json);
});
{
  const s = R.sessionAt("outline", { tag: 1620 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])))]), linked(closing(s, ["outline"])));
  check("r16 plain tail (the text entry is last): receipt recorded, stdout empty", silent(st) && R.receiptExists(s.sid, "outline"), { out: st.out, receipt: R.readReceiptRaw(s.sid, "outline") });
  const s2 = R.sessionAt("outline", { tag: 1621 });
  const st2 = ustop(s2, turn(s2, ["outline"], [A("a-anchor", T(closing(s2, ["outline"]))), THINK("a-red", "redacted_thinking")]), linked(closing(s2, ["outline"])));
  check("r16 redacted_thinking after the link close: receipt recorded", silent(st2) && R.receiptExists(s2.sid, "outline"), { out: st2.out });
}
}));
caseEnd();

caseBegin("r17-unrecorded-stage-notice", "hooks/stop-confirm-plan-guard.js");
test("r17-unrecorded-stage-notice", () => noNewFailures(failureCount, () => {
{
  const s = R.sessionAt("outline", { tag: 1711 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])), BASH("ls", "b1"))]));
  const msg = notice(st);
  check("r17 tool_use in the link entry + marker: no receipt", noReceipt(s.sid), STAGES.map((x) => R.readReceiptRaw(s.sid, x)));
  check("r17 tool_use in the link entry: stdout is one JSON object with systemMessage and no decision, rc 0", msg !== null, { rc: st.rc, out: st.out });
  check("r17 tool_use in the link entry: the notice names outline", names(msg, "outline"), msg);
  check("r17 the notice carries no URL", msg !== null && !/https?:\/\//i.test(msg), msg);
  const details = R.findings(s.sid).map((f) => show(f));
  check("r17 a supervisor finding is recorded with the notice", details.some((d) => d.includes("stop-confirm-plan-guard")), details);
  check("r17 the turn markers are spent", R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
}
{
  const s = R.sessionAt("outline", { tag: 1712 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"]))), A("a-tool", BASH("ls", "b1"))]));
  check("r17 a later assistant entry with tool_use: no receipt, notice names outline", noReceipt(s.sid) && names(notice(st), "outline"), { rc: st.rc, out: st.out });
}
{
  // Partial write: intent is left unpublished (no receipt link), outline is published.
  const s = R.sessionAt("outline", { tag: 1721 });
  const intent = R.linesFor(s.sid, "intent");
  fs.writeFileSync(intent.plan, R.EDITED_INTENT);
  const close = "Both plans are ready.\n\n" + `intent: \`${intent.fwd}\` (no URL: not-published)` + "\n" + s.urlLine;
  const st = ustop(s, turn(s, ["intent", "outline"], [A("a-anchor", T(close))]), Object.assign({ env: { CC_UNPUBLISHED_STAGE: "intent" } }, linked(close)));
  const msg = notice(st);
  check("r17 partial: no block", st.rc === 0 && !st.blocked, { rc: st.rc, out: st.out });
  check("r17 partial: the outline receipt is recorded, the intent one is not", R.receiptExists(s.sid, "outline") && !R.receiptExists(s.sid, "intent"),
    [R.readReceiptRaw(s.sid, "intent"), R.readReceiptRaw(s.sid, "outline")]);
  check("r17 partial: the notice names intent only", names(msg, "intent") && !names(msg, "outline"), { out: st.out });
}
{
  const s = R.sessionAt("outline", { tag: 1731 });
  const st = ustop(s, R.writeTranscript(s.sid, [U("list it", "u-p"), A("a-1", T("Ran the listing."), BASH("ls", "b1")), TR("b1", "u-b1")]));
  check("r17 no marker, no artifact named, anchor not formed: silent", silent(st) && noReceipt(s.sid), { rc: st.rc, out: st.out });
  const st2 = ustop(s, R.writeTranscript(s.sid, [U("thanks", "u-p"), A("a-1", T("All done."))]));
  check("r17 no marker, plain prose turn: silent", silent(st2) && noReceipt(s.sid), { rc: st2.rc, out: st2.out });
}
{
  const s = R.sessionAt("outline", { tag: 1741 });
  const tp = R.writeTranscript(s.sid, [U("update it", "u-p"), A("a-1", T("Updated it."), BASH("ls", "b1")), TR("b1", "u-b1")]);
  const st = ustop(s, tp, { input: { last_assistant_message: `I updated ${s.sid}-outline.md; please review the change.` } });
  const msg = notice(st);
  check("r17 only last_assistant_message names an existing artifact: notice names outline, not intent", names(msg, "outline") && !names(msg, "intent"), { rc: st.rc, out: st.out });
  const st2 = ustop(s, tp, { input: { last_assistant_message: `I updated ${s.sid}-detail.md; please review the change.` } });
  check("r17 last_assistant_message names an artifact that does not exist: silent", silent(st2), { rc: st2.rc, out: st2.out });
}
{
  const s = R.sessionAt("outline", { tag: 1751 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])))]), { env: { STOP_CONFIRM_CONTINUE_T0_OFFSET_MS: "100000" } });
  check("r17 budget spent: rc 0, no receipt, notice names outline", st.rc === 0 && noReceipt(s.sid) && names(notice(st), "outline"), { rc: st.rc, out: st.out });
}
{
  const s = R.sessionAt("outline", { tag: 1761 });
  const tail = [STR("a-str", closing(s, ["outline"]))];
  const st = R.stop(s.sid, turn(s, ["outline"], tail));
  check("r17 kind none (string content) + marker: no receipt, notice names outline", noReceipt(s.sid) && names(notice(st), "outline"), { rc: st.rc, out: st.out });
  check("r17 kind none: the turn markers are spent", R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
  const s2 = R.sessionAt("outline", { tag: 1762 });
  const st2 = R.stop(s2.sid, turn(s2, ["outline"], [STR("a-str", closing(s2, ["outline"]))], { markers: false }));
  check("r17 kind none without a marker: silent", silent(st2), { rc: st2.rc, out: st2.out });
}
}));
caseEnd();

caseBegin("r18-undecidable-tail-never-blocks", "hooks/stop-confirm-plan-guard.js");
test("r18-undecidable-tail-never-blocks", () => noNewFailures(failureCount, () => {
{
  const s = R.sessionAt("outline", { tag: 1801 });
  seedReceipts(s);
  const before = snap(s.sid);
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"]) + "\n\n" + QUESTION))]));
  check("r18 closeOnLink condition, undecidable: no block", st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
  check("r18 closeOnLink condition, undecidable: every seeded receipt is kept unchanged", sameAs(before, s.sid), { before, after: snap(s.sid) });
  check("r18 closeOnLink condition + marker, undecidable: stdout is one systemMessage JSON naming outline", names(notice(st), "outline"), { rc: st.rc, out: st.out });
}
{
  const s = R.sessionAt("outline", { tag: 1802 });
  seedReceipts(s);
  const before = snap(s.sid);
  const st = ustop(s, R.writeTranscript(s.sid, [U("go", "u-p"), A("a-echo", BASH(R.echoOf("outline"), "e1")), TR("e1", "u-e1")]));
  check("r18 layer2 condition, undecidable: no block", st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
  check("r18 layer2 condition, undecidable: every seeded receipt is kept unchanged", sameAs(before, s.sid), { before, after: snap(s.sid) });
  check("r18 layer2 condition, no marker, no artifact named: silent", silent(st), { rc: st.rc, out: st.out });
}
}));
caseEnd();

caseBegin("r19-stop-hook-active-undecidable", "hooks/stop-confirm-plan-guard.js");
test("r19-stop-hook-active-undecidable", () => noNewFailures(failureCount, () => {
{
  const s = R.sessionAt("outline", { tag: 1901 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])))]), linked(closing(s, ["outline"]), { stop_hook_active: true }));
  check("r19 active + undecidable, receipt recorded: stdout empty (nothing unrecorded), rc 0", silent(st), { rc: st.rc, out: st.out });
  check("r19 active + undecidable: the turn marker is kept (peek only)", R.turnMarkersLeft(s.sid) > 0, "markers=0");
  check("r19 active + undecidable: the receipt is recorded", R.receiptExists(s.sid, "outline"), "no receipt");
  const s2 = R.sessionAt("outline", { tag: 1902 });
  const st2 = ustop(s2, turn(s2, ["outline"], [A("a-anchor", T(closing(s2, ["outline"])), BASH("ls", "b1"))]), { input: { stop_hook_active: true } });
  check("r19 active + unrecordable presentation: no receipt", noReceipt(s2.sid), snap(s2.sid));
  check("r19 active + unrecordable presentation: stdout is one systemMessage JSON naming outline, rc 0, no decision", names(notice(st2), "outline"), { rc: st2.rc, out: st2.out });
  check("r19 active + unrecordable presentation: the turn marker is kept (peek only)", R.turnMarkersLeft(s2.sid) > 0, "markers=0");
  const s3 = R.sessionAt("outline", { tag: 1903 });
  const mid = [A("a-mid", T("Checking the plan files once more.")), A("a-tool", BASH("ls", "b9"))];
  const st3 = ustop(s3, turn(s3, ["outline"], mid), { input: { stop_hook_active: true, last_assistant_message: closing(s3, ["outline"]) + "\n\n" + QUESTION } });
  check("r19 active + D3b, final message not closing on the link line: no receipt", noReceipt(s3.sid), snap(s3.sid));
  check("r19 active + D3b, final message not closing on the link line: notice names outline, rc 0, no decision", names(notice(st3), "outline"), { rc: st3.rc, out: st3.out });
  check("r19 active + D3b: the turn marker is kept (peek only)", R.turnMarkersLeft(s3.sid) > 0, "markers=0");
}
}));
caseEnd();

caseBegin("decidable-presentation-keeps-continue", "hooks/stop-confirm-plan-guard.js");
test("decidable-presentation-keeps-continue", () => noNewFailures(failureCount, () => {
{
  const s = R.sessionAt("outline", { tag: 1951 });
  const close = closing(s, ["outline"]);
  const st = R.stop(s.sid, turn(s, ["outline"], [A("a-anchor", T(close))]), { input: { last_assistant_message: close } });
  check("decidable link close: the continue block is emitted", st.continued && st.reason.includes("WORKFLOW_CONFIRM_OUTLINE"), { rc: st.rc, out: st.out });
  check("decidable link close: the receipt is recorded and no systemMessage is added", R.receiptExists(s.sid, "outline") && !("systemMessage" in st.json), st.json);
}
}));
caseEnd();

caseBegin("undecidable-module-unit", "hooks/stop-confirm-plan-guard/undecidable.js");
test("undecidable-module-unit", () => noNewFailures(failureCount, () => UNIT.undecidableModuleUnit(check)));
caseEnd();

caseBegin("r20-undecidable-no-marker-records-receipt", "hooks/stop-confirm-plan-guard.js");
test("r20-undecidable-no-marker-records-receipt", () => noNewFailures(failureCount, () => {
STAGES.forEach((stage, i) => {
  const s = R.sessionAt(stage, { tag: 2001 + i });
  const st = ustop(s, turn(s, [stage], [A("a-anchor", T(closing(s, [stage])))], { markers: false }), linked(closing(s, [stage])));
  check(`r20 ${stage} no marker, undecidable link close: rc 0, stdout empty`, silent(st), { rc: st.rc, out: st.out });
  const rc = R.readReceiptRaw(s.sid, stage);
  check(`r20 ${stage} no marker: the receipt is recorded against the text entry`, rc !== null && rc.anchorUuid === "a-anchor", rc);
  const e = R.echo(s.sid, stage);
  check(`r20 ${stage} no marker: the echo after it reaches the dialog`, e.dialog, e.json);
});
}));
caseEnd();

caseBegin("r21-receipt-write-failure-notice", "hooks/stop-confirm-plan-guard.js");
test("r21-receipt-write-failure-notice", () => noNewFailures(failureCount, () => {
{
  const s = R.sessionAt("outline", { tag: 2101 });
  // A directory standing at the receipt path makes writeReceipt's final rename fail.
  const blocked = R.receiptPath(s.sid, "outline");
  fs.mkdirSync(blocked, { recursive: true });
  fs.writeFileSync(path.join(blocked, "occupant"), "x");
  const PR = require(path.join(R.ROOT, "hooks/lib/presentation-receipt"));
  const probe = PR.writeReceipt(s.sid, "outline", { absPath: s.plan, link: { kind: "url", value: s.url }, contentSha: "abc", anchorUuid: "a-probe" });
  check("r21 setup: a receipt write onto the occupied path fails", probe === false, "writeReceipt returned " + probe);
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])))]), linked(closing(s, ["outline"])));
  const msg = notice(st);
  check("r21 write failure, undecidable: stdout is one JSON object with systemMessage, rc 0, no decision", msg !== null, { rc: st.rc, out: st.out });
  check("r21 write failure: the notice names outline only", names(msg, "outline") && !names(msg, "intent") && !names(msg, "detail"), msg);
  fs.rmSync(blocked, { recursive: true, force: true });
  check("r21 write failure: no receipt is recorded", snap(s.sid).every((x) => x === null), snap(s.sid));
  const e = R.echo(s.sid, "outline");
  check("r21 write failure: the echo after it is denied (no-receipt)", e.denied && !e.dialog && e.reason.includes("(no-receipt)"), e.reason || e.json);
}
}));
caseEnd();

caseBegin("r22-gate-config-undecidable", "hooks/stop-confirm-plan-guard.js");
test("r22-gate-config-undecidable", () => noNewFailures(failureCount, () => {
for (const gate of ["on", "off"]) {
  const s = R.sessionAt("outline", { tag: gate === "on" ? 2201 : 2202 });
  const cfg = R.cfg({ CONFIRM_OUTLINE: gate });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"])))]), Object.assign({ cfg }, linked(closing(s, ["outline"]))));
  check(`r22 CONFIRM_OUTLINE=${gate}, undecidable link close: rc 0, stdout empty (no notice, no block, no continue)`, silent(st), { rc: st.rc, out: st.out });
  if (gate === "on") check("r22 CONFIRM_OUTLINE=on: the outline receipt is recorded", R.readReceiptRaw(s.sid, "outline") !== null, snap(s.sid));
  const e = R.echo(s.sid, "outline", { cfg });
  if (gate === "on") {
    check("r22 CONFIRM_OUTLINE=on: the echo reaches the dialog", e.dialog, e.json);
    check("r22 CONFIRM_OUTLINE=on: the receipt is consumed by the pass", !R.receiptExists(s.sid, "outline"), R.readReceiptRaw(s.sid, "outline"));
  } else {
    check("r22 CONFIRM_OUTLINE=off: no receipt is recorded", snap(s.sid).every((x) => x === null), snap(s.sid));
    check("r22 CONFIRM_OUTLINE=off: the echo is skipped", e.skipped, e.json);
  }
}
}));
caseEnd();

caseBegin("r23-unflushed-final-text-last-assistant-message", "hooks/stop-confirm-plan-guard.js");
test("r23-unflushed-final-text-last-assistant-message", () => noNewFailures(failureCount, () => D3B.r23(check)));
caseEnd();

caseBegin("r24-undecidable-path-link-receipt", "hooks/stop-confirm-plan-guard.js");
test("r24-undecidable-path-link-receipt", () => noNewFailures(failureCount, () => {
{
  // plan-sync off: the plan-link line names the local path, so the receipt binds a path link.
  const OFF = { mode: "plan-sync-off" };
  const pathClose = (s) => "Here is the plan.\n\n" + R.linesFor(s.sid, "outline").line;
  const s0 = R.sessionAt("outline", { tag: 2400 });
  R.stop(s0.sid, turn(s0, ["outline"], [A("a-anchor", T(pathClose(s0)))]), Object.assign({ input: { last_assistant_message: pathClose(s0) } }, OFF));
  const rc0 = R.readReceiptRaw(s0.sid, "outline");
  check("r24 control: a decidable path-link close records a path receipt", rc0 !== null && rc0.link && rc0.link.kind === "path", rc0);
  const s = R.sessionAt("outline", { tag: 2401 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(pathClose(s))), THINK("a-think")]), Object.assign(linked(pathClose(s)), OFF));
  const rc = R.readReceiptRaw(s.sid, "outline");
  check("r24 path link, link close then a thinking-only entry: stdout empty, path receipt on the text entry", silent(st) && rc !== null && rc.link && rc.link.kind === "path" && rc.anchorUuid === "a-anchor", { out: st.out, rc });
  const e = R.echo(s.sid, "outline", OFF);
  check("r24 path link, thinking-only tail: the echo reaches the dialog", e.dialog, e.json);
  const s2 = R.sessionAt("outline", { tag: 2402 });
  const mid = [A("a-mid", T("Checking the plan files once more.")), A("a-tool", BASH("ls", "b9"))];
  const st2 = ustop(s2, turn(s2, ["outline"], mid), Object.assign({ input: { last_assistant_message: pathClose(s2) } }, OFF));
  const rc2 = R.readReceiptRaw(s2.sid, "outline");
  check("r24 path link, final text only in last_assistant_message + marker: stdout empty, path receipt with anchorUuid \"\"", silent(st2) && rc2 !== null && rc2.link && rc2.link.kind === "path" && rc2.anchorUuid === "", { out: st2.out, rc: rc2 });
  const e2 = R.echo(s2.sid, "outline", OFF);
  check("r24 path link, D3b record: the echo reaches the dialog", e2.dialog, e2.json);
}
}));
caseEnd();

caseBegin("r25-unrecordable-undecidable-keeps-seeded-receipt", "hooks/stop-confirm-plan-guard.js");
test("r25-unrecordable-undecidable-keeps-seeded-receipt", () => noNewFailures(failureCount, () => {
// mid: the last text is mid-turn and the final text closes on the link line then a question.
// link: a text entry closing on the link line, a tool_use entry after it, an unmatched final message.
for (const [label, tag, tailOf, last] of [
  ["mid", 2501, () => [A("a-mid", T("Checking the plan files once more.")), A("a-tool", BASH("ls", "b9"))], (s) => closing(s, ["outline"]) + "\n\n" + QUESTION],
  ["link", 2502, (s) => [A("a-anchor", T(closing(s, ["outline"]))), A("a-tool", BASH("ls", "b9"))], () => MISMATCH],
]) {
  const s = R.sessionAt("outline", { tag });
  seedReceipts(s);
  const raw = () => STAGES.map((st) => { try { return fs.readFileSync(R.receiptPath(s.sid, st), "utf8"); } catch (_) { return null; } });
  const before = raw();
  const st = ustop(s, turn(s, ["outline"], tailOf(s)), { input: { last_assistant_message: last(s) } });
  check(`r25 ${label}: unrecordable undecidable turn: rc 0, no decision`, st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
  const after = raw();
  check(`r25 ${label}: every seeded receipt file is byte-equal`, before.every((b, i) => b !== null && b === after[i]), { before, after });
  const e = R.echo(s.sid, "outline");
  check(`r25 ${label}: the echo still reaches the dialog on the seeded receipt`, e.dialog, e.json);
}
}));
caseEnd();

caseBegin("r26-anchored-tail-final-message-not-closing-on-link", "hooks/stop-confirm-plan-guard.js");
test("r26-anchored-tail-final-message-not-closing-on-link", () => noNewFailures(failureCount, () => {
// The anchored text entry closes on the link line, but the real final message (MISMATCH) does not.
for (const [label, tailOf] of [
  ["thinking", (s, st) => [A("a-anchor", T(closing(s, [st]))), THINK("a-think")]],
  ["plain", (s, st) => [A("a-anchor", T(closing(s, [st])))]],
]) {
  STAGES.forEach((stage, i) => {
    const s = R.sessionAt(stage, { tag: 2600 + (label === "plain" ? 10 : 0) + i });
    const st = ustop(s, turn(s, [stage], tailOf(s, stage)));
    check(`r26 ${label} ${stage} + marker: rc 0, no block, no continue`, st.rc === 0 && !st.blocked && !st.continued && !("decision" in st.json), { rc: st.rc, out: st.out });
    check(`r26 ${label} ${stage} + marker: no receipt for ${stage}`, !R.receiptExists(s.sid, stage), R.readReceiptRaw(s.sid, stage));
    check(`r26 ${label} ${stage} + marker: the notice names ${stage}`, names(notice(st), stage), { rc: st.rc, out: st.out });
    check(`r26 ${label} ${stage}: the turn markers are spent`, R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
  });
}
STAGES.forEach((stage, i) => {
  const s = R.sessionAt(stage, { tag: 2620 + i });
  const st = ustop(s, turn(s, [stage], [A("a-anchor", T(closing(s, [stage]))), THINK("a-think")], { markers: false }));
  check(`r26 ${stage} no marker, message lacking the file name: no receipt`, noReceipt(s.sid), snap(s.sid));
  check(`r26 ${stage} no marker, message lacking the file name: stdout empty, rc 0`, silent(st), { rc: st.rc, out: st.out });
});
STAGES.forEach((stage, i) => {
  // A stage not presented by the final message is never passed to recordReceipts: its seeded receipt stays.
  const s = R.sessionAt(stage, { tag: 2630 + i });
  seedReceipts(s);
  const before = snap(s.sid);
  const st = ustop(s, turn(s, [stage], [A("a-anchor", T(closing(s, [stage]))), THINK("a-think")]));
  check(`r26 ${stage} seeded: every seeded receipt is kept byte-identical (not re-written with a-anchor)`, sameAs(before, s.sid), { before, after: snap(s.sid) });
  check(`r26 ${stage} seeded: the notice names ${stage}`, names(notice(st), stage), { rc: st.rc, out: st.out });
});
{
  const s = R.sessionAt("outline", { tag: 2641 });
  const st = ustop(s, turn(s, ["outline"], [A("a-anchor", T(closing(s, ["outline"]))), THINK("a-think")]), { input: { stop_hook_active: true } });
  check("r26 active + marker: no receipt", noReceipt(s.sid), snap(s.sid));
  check("r26 active + marker: notice names outline, rc 0, no decision", names(notice(st), "outline"), { rc: st.rc, out: st.out });
  check("r26 active: the turn marker is kept (peek only)", R.turnMarkersLeft(s.sid) > 0, "markers=0");
}
}));
caseEnd();

caseBegin("r27-undecidable-plan-lang-violation-no-receipt", "hooks/stop-confirm-plan-guard.js");
test("r27-undecidable-plan-lang-violation-no-receipt", () => noNewFailures(failureCount, () => {
// The undecidable path applies the decidable path's plan-lang check: a violating stage gets no receipt,
// keeps an earlier one, and is named in the notice. Clean-plan controls: r16 (anchored), r23 (D3b).
{
  const jaSession = (tag) => R.sessionAt("outline", { tag, body: jaBody("outline") });
  const pin = pinLang;
  const anchoredStop = (s, input) => anchoredLangStop(s, "outline", input);
  const d3bStop = (s) => d3bLangStop(s, "outline");
  const s0 = jaSession(2700);
  const close0 = closing(s0, ["outline"]);
  const st0 = R.stop(s0.sid, turn(s0, ["outline"], [A("a-anchor", T(close0))]), pin({ input: { last_assistant_message: close0 } }));
  check("r27 fixture: the decidable path blocks the same plan on plan-lang", st0.blocked && /plan-lang/i.test(st0.reason), { rc: st0.rc, out: st0.out });
  for (const [label, run, tag] of [["anchored", anchoredStop, 2701], ["d3b", d3bStop, 2702]]) {
    const s = jaSession(tag);
    const st = run(s);
    check(`r27 ${label}: rc 0, no decision`, st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
    check(`r27 ${label}: no receipt for the PLAN_LANG-violating outline`, !R.receiptExists(s.sid, "outline"), R.readReceiptRaw(s.sid, "outline"));
    check(`r27 ${label}: stdout is one systemMessage JSON naming outline`, names(notice(st), "outline"), { rc: st.rc, out: st.out });
    check(`r27 ${label}: the turn markers are spent`, R.turnMarkersLeft(s.sid) === 0, "markers=" + R.turnMarkersLeft(s.sid));
    const s2 = jaSession(tag + 10);
    seedReceipts(s2);
    const before = rawReceipts(s2.sid);
    const st2 = run(s2);
    const after = rawReceipts(s2.sid);
    check(`r27 ${label} seeded: every seeded receipt file is byte-equal (not re-written, not discarded)`, before.every((b, i) => b !== null && b === after[i]), { before, after });
    check(`r27 ${label} seeded: the notice names outline`, names(notice(st2), "outline"), { rc: st2.rc, out: st2.out });
  }
  {
    // Co-presented: intent edited after approval (clean, unapproved) and the violating outline.
    const s = jaSession(2721);
    fs.writeFileSync(R.linesFor(s.sid, "intent").plan, R.EDITED_INTENT);
    const close = closing(s, ["intent", "outline"]);
    const st = ustop(s, turn(s, ["intent", "outline"], [A("a-anchor", T(close)), THINK("a-think")]), pin(linked(close)));
    check("r27 co-presented: the clean intent gets its receipt", R.receiptExists(s.sid, "intent"), snap(s.sid));
    check("r27 co-presented: the violating outline gets none", !R.receiptExists(s.sid, "outline"), snap(s.sid));
    const msg = notice(st);
    check("r27 co-presented: the notice names outline only", names(msg, "outline") && !names(msg, "intent"), { rc: st.rc, out: st.out });
  }
  {
    const s = jaSession(2731);
    const st = anchoredStop(s, { stop_hook_active: true });
    check("r27 active: no receipt for the violating outline", !R.receiptExists(s.sid, "outline"), snap(s.sid));
    check("r27 active: notice names outline, rc 0, no decision", names(notice(st), "outline"), { rc: st.rc, out: st.out });
    check("r27 active: the turn marker is kept (peek only)", R.turnMarkersLeft(s.sid) > 0, "markers=0");
  }
}
}));
caseEnd();

caseBegin("r27-plan-lang-violation-intent-detail", "hooks/stop-confirm-plan-guard.js");
test("r27-plan-lang-violation-intent-detail", () => noNewFailures(failureCount, () => {
// CPR-ORTH: the plan-lang drop must hold for every stage, not only outline.
["intent", "detail"].forEach((stage, i) => {
  const jaAt = (tag) => R.sessionAt(stage, { tag, body: jaBody(stage) });
  const s0 = jaAt(2741 + 10 * i);
  const close0 = closing(s0, [stage]);
  const st0 = R.stop(s0.sid, turn(s0, [stage], [A("a-anchor", T(close0))]), pinLang({ input: { last_assistant_message: close0 } }));
  check(`r27 ${stage} fixture: the decidable path blocks the same plan on plan-lang`, st0.blocked && /plan-lang/i.test(st0.reason) && st0.reason.includes(`-${stage}.md`), { rc: st0.rc, out: st0.out });
  for (const [label, run, off] of [["anchored", (s) => anchoredLangStop(s, stage), 2], ["d3b", (s) => d3bLangStop(s, stage), 3]]) {
    const s = jaAt(2741 + 10 * i + off);
    const st = run(s);
    check(`r27 ${stage} ${label}: rc 0, no decision`, st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
    check(`r27 ${stage} ${label}: no receipt for the PLAN_LANG-violating ${stage}`, !R.receiptExists(s.sid, stage), R.readReceiptRaw(s.sid, stage));
    check(`r27 ${stage} ${label}: stdout is one systemMessage JSON naming ${stage}`, names(notice(st), stage), { rc: st.rc, out: st.out });
  }
});
}));
caseEnd();

caseBegin("r27-plan-lang-violation-marker-less-anchored", "hooks/stop-confirm-plan-guard.js");
test("r27-plan-lang-violation-marker-less-anchored", () => noNewFailures(failureCount, () => {
{
  // Re-presenting an existing violating outline without a turn marker; the link line names <sid>-outline.md.
  const s = R.sessionAt("outline", { tag: 2761, body: jaBody("outline") });
  const st = anchoredLangStop(s, "outline", undefined, { markers: false });
  check("r27 marker-less anchored: rc 0, no decision", st.rc === 0 && !("decision" in st.json), { rc: st.rc, out: st.out });
  check("r27 marker-less anchored: no receipt for the PLAN_LANG-violating outline", noReceipt(s.sid), snap(s.sid));
  check("r27 marker-less anchored: the notice names outline (the link line names its plan file)", names(notice(st), "outline"), { rc: st.rc, out: st.out });
}
}));
caseEnd();

caseBegin("r27-plan-lang-allowed-records-receipt", "hooks/stop-confirm-plan-guard.js");
test("r27-plan-lang-allowed-records-receipt", () => noNewFailures(failureCount, () => {
// Positive controls: the same Japanese-prose outline is clean under PLAN_LANG=japanese (strict) and any (noop).
["japanese", "any"].forEach((lang, i) => {
  const s0 = R.sessionAt("outline", { tag: 2777 + i, body: jaBody("outline") });
  const close0 = closing(s0, ["outline"]);
  const st0 = R.stop(s0.sid, turn(s0, ["outline"], [A("a-anchor", T(close0))]), pinLang({ input: { last_assistant_message: close0 } }, lang));
  check(`r27 PLAN_LANG=${lang} sanity: the decidable path emits the continue block, not a plan-lang block, and records the receipt`,
    st0.continued && !/plan-lang/i.test(st0.reason) && R.receiptExists(s0.sid, "outline"), { rc: st0.rc, out: st0.out });
  for (const [label, run, off] of [["anchored", (s) => anchoredLangStop(s, "outline", undefined, undefined, lang), 0], ["d3b", (s) => d3bLangStop(s, "outline", lang), 1]]) {
    const s = R.sessionAt("outline", { tag: 2771 + 2 * i + off, body: jaBody("outline") });
    const st = run(s);
    check(`r27 PLAN_LANG=${lang} ${label}: rc 0, stdout empty (no decision, no notice)`, silent(st), { rc: st.rc, out: st.out });
    check(`r27 PLAN_LANG=${lang} ${label}: the outline receipt is recorded`, R.receiptExists(s.sid, "outline"), snap(s.sid));
  }
});
}));
caseEnd();

caseBegin("r28-d3b-marker-less-re-present", "hooks/stop-confirm-plan-guard.js");
test("r28-d3b-marker-less-re-present", () => noNewFailures(failureCount, () => D3B.r28(check)));
caseEnd();

caseBegin("r29-undecidable-unpublished-keeps-receipt", "hooks/stop-confirm-plan-guard.js");
test("r29-undecidable-unpublished-keeps-receipt", () => noNewFailures(failureCount, () => D3B.r29(check)));
caseEnd();

caseBegin("r30-anchored-final-only-stage", "hooks/stop-confirm-plan-guard.js");
test("r30-anchored-final-only-stage", () => noNewFailures(failureCount, () => ANCH.r30(check)));
caseEnd();
