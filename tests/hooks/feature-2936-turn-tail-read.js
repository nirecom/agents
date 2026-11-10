#!/usr/bin/env node
// tests/hooks/feature-2936-turn-tail-read.js
// Tests: hooks/lib/transcript-reader.js, hooks/lib/transcript-reader/tail-window.js
// Tags: TL2, hooks, transcript-reader, stop-guard, hook-timeout, scope:issue-specific
// TL3 gap: the host's real flush timing of the final transcript line and real multi-MB transcripts
// under parallel Stop hooks; mitigated by bin/check-verification-gate.sh (category: hook-registration).
// #2936: readTurnTail reads a bounded tail window (256 KiB, growing x4 up to BOF) instead of the whole
// transcript, re-reads only the appended bytes while it waits for the flush, and stops at deadlineAt.
"use strict";

const { after: afterAll, test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2936tr-"));
afterAll(() => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const Z = require("./feature-2936-turn-tail-read/fixture");
const { U, A, T, TU, TRS, W0 } = Z;
const TR = require(path.join(Z.ROOT, "hooks/lib/transcript-reader"));
const read = (p, more) => TR.readTurnTail(Object.assign({ input: { transcript_path: p } }, more || {}));
const sizeOf = (p) => fs.statSync(p).size;
const JA = String.fromCharCode(0x3042);
const EMOJI = String.fromCodePoint(0x1f600);

caseBegin("tail-window-exports-the-initial-window", "hooks/lib/transcript-reader/tail-window.js");
test("tail-window-exports-the-initial-window", () => {
  const TW = Z.tryRequire("hooks/lib/transcript-reader/tail-window");
  assert.equal(TW.__missing, undefined, `tail-window.js does not load: ${TW.__missing}`);
  assert.equal(TW.TAIL_INITIAL_BYTES, W0);
  assert.equal(typeof TR.refreshTurnTail, "function", "transcript-reader exports refreshTurnTail");
});
caseEnd();

caseBegin("small-transcript-tail-equals-the-full-read", "hooks/lib/transcript-reader.js");
test("small-transcript-tail-equals-the-full-read", () => {
  const p = Z.write(SCRATCH, [U("first", "u-1"), A("a-1", T("one")), U("second", "u-2"), A("a-2", TU("t1")), TRS("t1", "u-r"), A("a-3", T("two"))]);
  const full = Z.fullRead(TR, p);
  const t = read(p);
  assert.deepEqual(t.lines, full.lines);
  assert.deepEqual(t.entries, full.entries);
  assert.deepEqual([t.lastAssistantEntry, t.lastTextBlock, t.lastTextEntry], [full.tail.lastAssistantEntry, full.tail.lastTextBlock, full.tail.lastTextEntry]);
  assert.equal(t.undecidable, false);
  assert.equal(t.complete, true);
  assert.equal(t.span && t.span.end, sizeOf(p), "span.end sits after the last newline");
});
test("turns-2-keeps-the-previous-prompt-in-a-bounded-window", () => {
  const p = Z.write(SCRATCH, Z.history(600 * 1024).concat([U("prev", "u-p1"), A("a-p1", T("prev answer")), U("cur", "u-p2"), A("a-p2", T("cur answer"))]));
  const full = Z.fullRead(TR, p);
  const t1 = read(p);
  const t2 = read(p, { turns: 2 });
  for (const t of [t1, t2]) {
    assert.ok(Z.isSuffix(t.entries, full.entries), "entries are the file's last entries");
    assert.ok(t.entries.length < full.entries.length, "the window did not read the whole history");
    assert.equal(t.complete, true);
    assert.equal(Z.key(t.lastTextEntry), Z.key(full.tail.lastTextEntry));
  }
  assert.ok(t1.lines.length < full.lines.length);
  assert.ok(Z.uuids(t1.entries).includes("u-p2"));
  assert.ok(Z.uuids(t2.entries).includes("u-p1") && Z.uuids(t2.entries).includes("u-p2"));
});
caseEnd();

caseBegin("window-grows-to-the-prompt-reading-at-most-1-4x-the-last-window", "hooks/lib/transcript-reader.js");
test("window-grows-to-the-prompt-reading-at-most-1-4x-the-last-window", () => {
  const big = "r".repeat(600 * 1000);
  const p = Z.write(SCRATCH, Z.history(3 * 1024 * 1024).concat([U("cur", "u-cur"), A("a-c1", TU("t-big")), TRS("t-big", "u-big", big), A("a-c2", T("done"))]));
  const full = Z.fullRead(TR, p);
  const spy = Z.spyReads(p, () => read(p));
  const t = spy.value;
  assert.equal(spy.fullReads, 0, "no whole-file read");
  assert.ok(Z.uuids(t.entries).includes("u-cur"), "the window reached the current prompt");
  const tr = (t.entries || []).find((e) => e.uuid === "u-big");
  assert.ok(tr && tr.message.content[0].content.length === big.length, "the 600 KB line is read whole");
  assert.ok(Z.isSuffix(t.entries, full.entries) && t.entries.length < full.entries.length, "bounded, not BOF");
  assert.equal(t.complete, true);
  assert.equal(t.undecidable, false);
  const lastWindow = W0 * 4;
  assert.ok(spy.bytes > 600 * 1000 && spy.bytes <= 1.4 * lastWindow, `bytes read ${spy.bytes} vs last window ${lastWindow}`);
});
caseEnd();

// The window start falls inside one multibyte character of a line longer than the window.
function noBrokenLines(t) {
  assert.ok(Array.isArray(t.lines) && t.lines.length > 0);
  for (const l of t.lines) {
    assert.ok(!l.includes("�"), "no replacement character");
    assert.doesNotThrow(() => JSON.parse(l), "every returned line is a whole JSON line");
  }
}
caseBegin("window-start-inside-a-multibyte-character-breaks-no-entry", "hooks/lib/transcript-reader.js");
for (const [label, ch] of [["japanese", JA], ["surrogate-pair", EMOJI]]) {
  test(`${label}: a prompt line longer than the window is read whole`, () => {
    const text = ch.repeat(Math.ceil(300 * 1024 / Buffer.byteLength(ch)));
    const entries = Z.midChar((pad) => Z.history(400 * 1024).concat([U(text, "u-long"), A("a-ans", T("answer" + "x".repeat(pad)))]), ch);
    const p = Z.write(SCRATCH, entries);
    const t = read(p);
    noBrokenLines(t);
    const prompt = (t.entries || []).find((e) => e.uuid === "u-long");
    assert.ok(prompt && prompt.message.content === text, "the prompt text is intact");
    assert.ok(Z.isSuffix(t.entries, Z.fullRead(TR, p).entries));
  });
  test(`${label}: a history line cut by the window start is dropped, every whole line is kept`, () => {
    const text = ch.repeat(Math.ceil(300 * 1024 / Buffer.byteLength(ch)));
    const entries = Z.midChar((pad) => Z.history(200 * 1024).concat([A("a-long", T(text)), U("cur", "u-cur"), A("a-ans", T("answer" + "x".repeat(pad)))]), ch);
    const p = Z.write(SCRATCH, entries);
    const full = Z.fullRead(TR, p);
    const t = read(p);
    noBrokenLines(t);
    assert.ok(Z.isSuffix(t.entries, full.entries));
    assert.deepEqual(Z.uuids(t.entries).slice(-2), ["u-cur", "a-ans"]);
    const long = (t.entries || []).find((e) => e.uuid === "a-long");
    assert.ok(!long || long.message.content[0].text === text, "the long line is absent or whole");
  });
}
caseEnd();

caseBegin("no-prompt-or-unmet-reachedBy-reads-to-bof", "hooks/lib/transcript-reader.js");
test("a transcript without a real prompt is read to BOF", () => {
  const p = Z.write(SCRATCH, Z.history(700 * 1024, { prompts: false }));
  const full = Z.fullRead(TR, p);
  const t = read(p);
  assert.equal(t.complete, true);
  assert.equal(t.undecidable, false);
  assert.deepEqual(t.entries, full.entries);
});
test("reachedBy widens the window to the matching entry and stops there", () => {
  const p = Z.write(SCRATCH, Z.history(2 * 1024 * 1024).concat([A("a-head", T("## HEADING-2936"))], Z.history(400 * 1024), [U("cur", "u-cur"), A("a-c", T("end"))]));
  const full = Z.fullRead(TR, p);
  const seen = [];
  const t = read(p, { reachedBy: (e) => { seen.push(e); return TR.textItemsOf(e).some((x) => x.includes("HEADING-2936")); } });
  assert.ok(seen.length > 0 && seen.every((e) => e && typeof e === "object"), "reachedBy is called with entries");
  assert.ok(Z.uuids(t.entries).includes("a-head"));
  assert.ok(Z.isSuffix(t.entries, full.entries) && t.entries.length < full.entries.length, "stops before BOF");
  const none = read(p, { reachedBy: () => false });
  assert.equal(none.complete, true);
  assert.deepEqual(none.entries, full.entries, "an unmet reachedBy reads to BOF");
});
caseEnd();

const MSG = "final words of the turn 2936";
const finalLine = JSON.stringify(A("a-final", T(MSG))) + "\n";
caseBegin("flush-wait-reads-only-the-appended-bytes", "hooks/lib/transcript-reader.js");
test("a child appending the final line during the wait ends it flushed", async () => {
  const p = Z.write(SCRATCH, Z.history(50 * 1024).concat([U("cur", "u-cur"), A("a-mid", T("working"))]));
  const size0 = sizeOf(p);
  const job = Z.appendLater("append", p, finalLine, 150);
  await job.ready;
  const spy = Z.spyReads(p, () => read(p, { input: { transcript_path: p, last_assistant_message: MSG } }));
  await job.done;
  assert.equal(spy.value.undecidable, false);
  assert.equal(spy.value.lastTextBlock, MSG);
  assert.equal(spy.fullReads, 0, "no whole-file re-read");
  assert.ok(spy.bytes <= size0 + Buffer.byteLength(finalLine), `bytes ${spy.bytes} > first read + append`);
});
test("an unterminated last line completed later is committed once", async () => {
  const half = Math.floor(finalLine.length / 2);
  const p = Z.write(SCRATCH, [U("cur", "u-cur"), A("a-mid", T("working"))], finalLine.slice(0, half));
  const job = Z.appendLater("append", p, finalLine.slice(half), 150);
  await job.ready;
  const t = read(p, { input: { transcript_path: p, last_assistant_message: MSG } });
  await job.done;
  assert.equal(t.undecidable, false);
  assert.equal(t.lastTextBlock, MSG);
  assert.equal(Z.uuids(t.entries).filter((u) => u === "a-final").length, 1);
  assert.equal(t.span && t.span.end, sizeOf(p));
});
test("a transcript rewritten smaller during the wait is read again from the first window", async () => {
  const p = Z.write(SCRATCH, Z.history(120 * 1024).concat([U("cur", "u-cur"), A("a-mid", T("working"))]));
  const fresh = Z.jsonl([U("again", "u-new"), A("a-final", T(MSG))]);
  const job = Z.appendLater("rewrite", p, fresh, 150);
  await job.ready;
  const t = read(p, { input: { transcript_path: p, last_assistant_message: MSG } });
  await job.done;
  assert.equal(t.undecidable, false);
  assert.equal(t.lastTextBlock, MSG);
  assert.deepEqual(Z.uuids(t.entries), ["u-new", "a-final"]);
});
caseEnd();

caseBegin("refresh-turn-tail-reads-the-append-and-is-idempotent", "hooks/lib/transcript-reader.js");
test("refreshTurnTail after an append reads only the appended bytes", () => {
  const p = Z.write(SCRATCH, Z.history(100 * 1024).concat([U("cur", "u-cur"), A("a-mid", T("working"))]));
  const t0 = read(p);
  fs.appendFileSync(p, finalLine);
  const spy = Z.spyReads(p, () => TR.refreshTurnTail(t0, { input: { transcript_path: p } }));
  assert.equal(spy.fullReads, 0);
  assert.ok(spy.bytes <= Buffer.byteLength(finalLine), `refresh read ${spy.bytes} bytes`);
  assert.deepEqual(spy.value.entries, t0.entries.concat([JSON.parse(finalLine)]));
  assert.equal(spy.value.lastTextBlock, MSG);
});
test("refreshTurnTail without an append and a second read return the same tail", () => {
  const p = Z.write(SCRATCH, Z.history(300 * 1024).concat([U("cur", "u-cur"), A("a-c", T("end"))]));
  const t0 = read(p);
  const again = read(p);
  const pick = (t) => Z.key([t.lines, t.entries, t.span, t.complete, t.undecidable, t.lastTextBlock]);
  assert.equal(pick(again), pick(t0), "two reads agree");
  assert.equal(pick(TR.refreshTurnTail(t0, { input: { transcript_path: p } })), pick(t0), "refresh without an append changes nothing");
});
test("refreshTurnTail after a shrink re-reads, and an unreadable file is undecidable without a throw", () => {
  const p = Z.write(SCRATCH, Z.history(100 * 1024).concat([U("cur", "u-cur"), A("a-mid", T("working"))]));
  const t0 = read(p);
  fs.writeFileSync(p, Z.jsonl([U("again", "u-new"), A("a-final", T(MSG))]));
  assert.deepEqual(Z.uuids(TR.refreshTurnTail(t0, { input: { transcript_path: p } }).entries), ["u-new", "a-final"]);
  fs.rmSync(p);
  let r;
  assert.doesNotThrow(() => { r = TR.refreshTurnTail(t0, { input: { transcript_path: p } }); });
  assert.equal(r && r.undecidable, true);
});
caseEnd();

caseBegin("unreadable-input-and-a-spent-deadline-fail-safe", "hooks/lib/transcript-reader.js");
test("a missing, empty or absent path reads as no lines without a throw", () => {
  const empty = Z.write(SCRATCH, []);
  fs.writeFileSync(empty, "");
  for (const input of [{ transcript_path: path.join(SCRATCH, "nope.jsonl") }, { transcript_path: empty }, { transcript_path: "" }, {}]) {
    let t;
    assert.doesNotThrow(() => { t = TR.readTurnTail({ input }); });
    assert.deepEqual(t.lines, [], Z.key(input));
    assert.deepEqual(t.entries, [], Z.key(input));
  }
  const broken = Z.write(SCRATCH, []);
  fs.writeFileSync(broken, "{not json\n[1,\n");
  let b;
  assert.doesNotThrow(() => { b = read(broken); });
  assert.deepEqual(b.entries, []);
  assert.equal(b.lastAssistantEntry, null);
});
test("a past deadlineAt reads only the first window and returns undecidable fast", () => {
  const p = Z.write(SCRATCH, Z.history(3 * 1024 * 1024).concat([U("cur", "u-cur"), A("a-c1", TU("t-big")), TRS("t-big", "u-big", "r".repeat(600 * 1000))]));
  const t0 = Date.now();
  const spy = Z.spyReads(p, () => read(p, { input: { transcript_path: p, last_assistant_message: "never flushed 2936" }, deadlineAt: Date.now() - 1 }));
  const ms = Date.now() - t0;
  assert.equal(spy.value.undecidable, true);
  assert.equal(spy.fullReads, 0);
  assert.ok(spy.bytes > 0 && spy.bytes <= W0, `bytes ${spy.bytes}: the first window only`);
  assert.ok(ms < 400, `took ${ms} ms: no growth and no flush sleep after the deadline`);
});
test("a past deadlineAt with the final message flushed but the prompt before the first window: incomplete and undecidable", () => {
  const p = Z.write(SCRATCH, Z.history(1024 * 1024).concat([U("cur", "u-cur"), A("a-c1", TU("t-big")), TRS("t-big", "u-big", "r".repeat(600 * 1000)), A("a-final", T(MSG))]));
  const t0 = Date.now();
  const spy = Z.spyReads(p, () => read(p, { input: { transcript_path: p, last_assistant_message: MSG }, deadlineAt: Date.now() - 1 }));
  const ms = Date.now() - t0;
  const t = spy.value;
  assert.equal(t.lastTextBlock, MSG, "premise: the final message is in the first window (flushed)");
  assert.ok(Array.isArray(t.entries) && Z.uuids(t.entries).includes("a-final"), "the window's entries are returned");
  assert.ok(!Z.uuids(t.entries).includes("u-cur"), "the current prompt was not reached");
  assert.equal(t.complete, false, "the turn boundary is outside the window");
  assert.equal(t.undecidable, true, "a flushed tail without its prompt is still undecidable");
  assert.ok(spy.bytes > 0 && spy.bytes <= W0, `bytes ${spy.bytes}: the first window only`);
  assert.ok(ms < 400, `took ${ms} ms: no growth after the deadline`);
});
caseEnd();
