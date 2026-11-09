#!/usr/bin/env node
// tests/hooks/feature-2936-receipt-recovery.js
// Tests: hooks/confirm-checkpoint/receipt-recovery.js, hooks/confirm-checkpoint.js, hooks/lib/presentation-turn.js, hooks/lib/turn-marker.js
// Tags: TL2, hooks, confirm-checkpoint, confirm-plan, presentation-receipt, receipt-recovery, turn-marker, scope:issue-specific
// TL3 gap: a real Stop hook killed by the host between the presentation and its receipt write; here
// the Stop never runs, and the transcript, markers and plan mtime are what a killed Stop leaves behind.
// #2936 S12: with no receipt, confirm-checkpoint records one from the previous turn only when that turn
// passes the Stop's own presentation check (judgePresentationTurn); otherwise it denies no-receipt with
// the Stop-timeout hint and leaves the markers. Replays, later edits and broken inputs never recover.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2936rr-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.PLAN_LANG;
delete process.env.CONV_LANG;
process.chdir(SCRATCH);
afterAll(() => {
  process.chdir(os.tmpdir());
  restore();
  try { fs.rmSync(SCRATCH, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const R = require("./feature-2729-presentation-receipt/fixture");
const K = require("./feature-2936-stop-budget-kill/fixture");
const P = require("./feature-2936-receipt-recovery/fixture");

let tag = 9500;
const at = (stage, o) => R.sessionAt(stage || "outline", Object.assign({ tag: ++tag }, o || {}));
const why = (c) => String((c.json.hookSpecificOutput || {}).permissionDecisionReason || "");
const show = (c) => JSON.stringify({ rc: c.rc, calls: c.calls, written: c.written, why: why(c).slice(0, 200), msg: c.msg, err: String(c.err || "").slice(0, 200) });
// failClosed(c, s, before, cause) -> the echo was denied for `cause` with the hint, wrote no receipt,
// and left the turn markers as `before` listed them.
function failClosed(c, s, before, cause) {
  assert.ok(c.denied && !c.dialog, `denied: ${show(c)}`);
  assert.ok(why(c).includes(`(${cause || "no-receipt"})`), `cause ${cause || "no-receipt"}: ${show(c)}`);
  if (!cause || cause === "no-receipt") assert.ok(why(c).includes(P.HINT), `the deny carries the hint: ${show(c)}`);
  assert.ok(!R.receiptExists(s.sid, s.step), "no receipt is written");
  assert.ok(!P.events(s.sid, s.step).includes("write"), "the receipt log has no write");
  assert.deepEqual(P.markerTimes(s.sid), before, "the markers are left as they were");
}
const calledOnceUnwritten = (c) => assert.ok(c.calls === 1 && c.written.length === 1 && c.written[0] === false, `recoverReceipt ran once, wrote nothing: ${show(c)}`);

caseBegin("previous-turn-presentation-is-recovered", "hooks/confirm-checkpoint/receipt-recovery.js");
test("no receipt, no log write, the previous turn closes on the link: recovered, spent, markers split at the opener", () => {
  const s = at();
  const k = P.pair(s, { markers: [[s.stage, 1000], [s.stage, 3000]] });
  const c = P.confirm(s, { tp: k.tp });
  assert.ok(c.dialog, `the dialog follows: ${show(c)}`);
  assert.deepEqual(c.written, [true], show(c));
  assert.deepEqual(P.events(s.sid, s.step), ["write", "consume"], "the log records the write, then the consume");
  assert.ok(!R.receiptExists(s.sid, s.step), "the recovered receipt is spent by the dialog");
  assert.ok(P.recoveredFinding(s.sid, s.step), `the recovered finding: ${JSON.stringify(R.findings(s.sid))}`);
  assert.deepEqual(P.markerTimes(s.sid), [k.at(3000)], "only the marker written after the opener is left");
});
caseEnd();

caseBegin("no-evidence-denies-with-the-hint", "hooks/confirm-checkpoint.js");
const NO_EVIDENCE = [
  ["text after the link line", (s) => ({ last: K.closingOf(s) + "\n\nAnything else?" })],
  ["the step already approved", () => ({}), { approved: true }],
  ["a plan-link block from the previous turn's markers", (s) => ({ markers: [[s.stage, 1000], ["intent", 1000]] })],
];
for (const [name, mk, sOpts] of NO_EVIDENCE) {
  test(`${name}: recoverReceipt runs and writes nothing; no-receipt deny with the hint`, () => {
    const s = at("outline", sOpts);
    const k = P.pair(s, mk(s));
    const before = P.markerTimes(s.sid);
    const c = P.confirm(s, { tp: k.tp });
    failClosed(c, s, before);
    calledOnceUnwritten(c);
  });
}
test("an unpublished plan: the unpublished deny comes before any receipt read, so no recovery", () => {
  const s = at();
  const k = P.pair(s, { last: "Here is the plan.\n\n" + P.unpublishedLine(s) });
  const before = P.markerTimes(s.sid);
  const c = P.confirm(s, { tp: k.tp, env: { CC_UNPUBLISHED_STAGE: "outline" } });
  failClosed(c, s, before, "unpublished");
  assert.equal(c.calls, 0, show(c));
});
caseEnd();

caseBegin("exits-before-the-receipt-never-recover", "hooks/confirm-checkpoint.js");
test("plan-size over HARD: the size deny, recoverReceipt never called, receipt and markers untouched", () => {
  const s = at();
  P.hardPlan(s);
  const k = P.pair(s);
  const before = P.markerTimes(s.sid);
  const c = P.confirm(s, { tp: k.tp });
  assert.ok(c.denied && why(c).includes("plan-size:") && why(c).includes("over HARD"), show(c));
  assert.equal(c.calls, 0, show(c));
  assert.ok(!R.receiptExists(s.sid, s.step));
  assert.deepEqual(P.markerTimes(s.sid), before);
});
test("gate OFF: [confirm-skipped], recoverReceipt never called, receipt and markers untouched", () => {
  const s = at();
  const k = P.pair(s);
  const before = P.markerTimes(s.sid);
  const c = P.confirm(s, { tp: k.tp, cfg: R.cfg({ CONFIRM_OUTLINE: "off" }) });
  assert.ok(c.skipped, show(c));
  assert.equal(c.calls, 0, show(c));
  assert.ok(!R.receiptExists(s.sid, s.step));
  assert.deepEqual(P.markerTimes(s.sid), before);
});
caseEnd();

caseBegin("recovery-and-stop-share-one-judgment", "hooks/lib/presentation-turn.js");
// Each fixture: the turn-N closing, its markers and the session options, shared by both paths.
const KINDS = [
  ["clean presentation", (s) => ({ last: K.closingOf(s) })],
  ["not-last", (s) => ({ last: K.closingOf(s) + "\n\nAnything else?" })],
  ["plan-link (another stage's marker)", (s) => ({ last: K.closingOf(s), markers: [[s.stage, 1000], ["intent", 1000]] })],
  ["plan-link (the local line)", (s) => ({ last: "Here is the plan.\n\n" + s.line })],
  ["approved", (s) => ({ last: K.closingOf(s) }), { approved: true }],
];
for (const [name, mk, sOpts] of KINDS) {
  test(`${name}: the Stop writes a receipt exactly when the recovery does`, () => {
    const a = at("outline", sOpts);
    const fa = mk(a);
    for (const [stage] of (fa.markers || []).filter(([st]) => st !== a.stage)) R.turnMarker(a.sid, stage, R.linesFor(a.sid, stage).plan);
    R.stop(a.sid, R.presentTurn(a, [a.stage], fa.last), { env: K.LANG_ENV });
    const stopWrote = R.receiptExists(a.sid, a.step);
    const b = at("outline", sOpts);
    const c = P.confirm(b, { tp: P.pair(b, mk(b)).tp });
    assert.equal(c.dialog, stopWrote, `stop wrote ${stopWrote}, recovery: ${show(c)}`);
    assert.equal(c.calls, 1, show(c));
    if (name === "clean presentation") assert.equal(stopWrote, true, "premise: the clean presentation is recorded");
  });
}
for (const [name, prep, cfg] of [["gate OFF", () => {}, { CONFIRM_OUTLINE: "off" }], ["plan-size HARD", P.hardPlan, null]]) {
  test(`${name}: judgePresentationTurn called directly agrees with the Stop`, () => {
    const a = at();
    prep(a);
    R.stop(a.sid, R.presentTurn(a, [a.stage], K.closingOf(a)), { env: K.LANG_ENV, cfg: cfg ? R.cfg(cfg) : undefined });
    const b = at();
    prep(b);
    const v = P.direct(["judge", b.sid, R.presentTurn(b, [b.stage], K.closingOf(b)), b.stage], { cfg: cfg ? R.cfg(cfg) : undefined });
    assert.equal(v.missing, undefined, `the modules load: ${JSON.stringify(v)}`);
    assert.equal(v.writes, R.receiptExists(a.sid, a.step), JSON.stringify(v));
  });
}
test("stop_hook_active (and active / input) passed in does not change judgePresentationTurn", () => {
  for (const last of [(s) => K.closingOf(s), (s) => K.closingOf(s) + "\n\nAnything else?"]) {
    const s = at();
    const tp = R.presentTurn(s, [s.stage], last(s));
    const plain = P.direct(["judge", s.sid, tp, s.stage]);
    assert.equal(plain.missing, undefined, `the modules load: ${JSON.stringify(plain)}`);
    assert.deepEqual(P.direct(["judge", s.sid, tp, s.stage, "active"]), plain);
  }
});
caseEnd();

caseBegin("replay-and-tamper-never-recover", "hooks/confirm-checkpoint/receipt-recovery.js");
const TAMPER = [
  ["a write and consume after the anchor (a Deny)", (s) => {
    const PR = require(path.join(R.ROOT, "hooks/lib/presentation-receipt"));
    assert.ok(PR.writeReceipt(s.sid, s.step, { absPath: s.plan, link: { kind: "url", value: s.url }, contentSha: R.sha256(s.plan), anchorUuid: "a-anchor" }));
    assert.ok(PR.consumeReceipt(s.sid, s.step));
    return {};
  }],
  ["only a consume (no write) after the anchor", (s) => {
    P.logEvent(s.sid, s.step, "consume", new Date().toISOString());
    assert.deepEqual(P.events(s.sid, s.step), ["consume"], "premise: the log holds the consume only");
    return {};
  }],
  ["the plan edited after the anchor", () => ({ planMs: 1500 })],
  ["an anchor without a uuid", () => ({ anchorUuid: null })],
  ["an anchor without a timestamp", () => ({ anchorTs: false })],
  ["an opener without a timestamp", () => ({ openerTs: false })],
  ["the CONFIRM in the presentation turn itself", () => ({ sameTurn: true })],
];
for (const [name, mk] of TAMPER) {
  test(`${name}: no recovery, the no-receipt deny`, () => {
    const s = at();
    const opts = mk(s);
    const k = P.pair(s, opts);
    const before = P.markerTimes(s.sid);
    const logBefore = P.events(s.sid, s.step);
    const c = P.confirm(s, { tp: k.tp });
    assert.ok(c.denied && why(c).includes("(no-receipt)") && why(c).includes(P.HINT), show(c));
    assert.ok(!R.receiptExists(s.sid, s.step));
    assert.deepEqual(P.events(s.sid, s.step), logBefore, "the recovery adds no log record");
    assert.deepEqual(P.markerTimes(s.sid), before);
    calledOnceUnwritten(c);
  });
}
caseEnd();

caseBegin("receipt-log-before-the-anchor-allows-recovery", "hooks/confirm-checkpoint/receipt-recovery.js");
test("a write and consume of the same step before the anchor (an earlier presentation): recovered", () => {
  const s = at();
  const k = P.pair(s);
  P.logEvent(s.sid, s.step, "write", k.at(-30000));
  P.logEvent(s.sid, s.step, "consume", k.at(-29000));
  assert.deepEqual(P.events(s.sid, s.step), ["write", "consume"], "premise: the earlier records are in the log");
  const c = P.confirm(s, { tp: k.tp });
  assert.ok(c.dialog, `the dialog follows: ${show(c)}`);
  assert.deepEqual(c.written, [true], show(c));
  assert.deepEqual(P.events(s.sid, s.step), ["write", "consume", "write", "consume"], "the recovery appends its own write and consume");
});
caseEnd();

caseBegin("consume-turn-markers-before", "hooks/lib/turn-marker.js");
test("consumeTurnMarkersBefore: earlier markers go; equal, later, missing and broken created_at stay; never throws", () => {
  require("./feature-2936-receipt-recovery/marker-consume").consumeBefore();
});
caseEnd();

caseBegin("abnormal-inputs-fail-closed", "hooks/confirm-checkpoint/receipt-recovery.js");
const ABNORMAL = [
  ["no transcript_path", () => ({ tp: undefined })],
  ["a transcript_path that does not exist", () => ({ tp: path.join(SCRATCH, "missing.jsonl") })],
  ["only one real prompt", (s) => ({ tp: P.pair(s, { onePrompt: true }).tp })],
];
for (const [name, mk] of ABNORMAL) {
  test(`${name}: no recovery, the no-receipt deny`, () => {
    const s = at();
    if (name !== "only one real prompt") P.pair(s);
    const o = mk(s);
    const before = P.markerTimes(s.sid);
    const c = P.confirm(s, { tp: o.tp });
    failClosed(c, s, before);
    calledOnceUnwritten(c);
  });
}
test("a spent deadline (deadlineAt injected) does not recover; the same pair with time left does", () => {
  const s = at();
  const short = P.direct(["recover", s.sid, P.pair(s).tp, s.step, s.stage, "1000"]);
  assert.equal(short.missing, undefined, `the modules load: ${JSON.stringify(short)}`);
  assert.equal(short.written, false, JSON.stringify(short));
  assert.ok(!R.receiptExists(s.sid, s.step));
  const ok = at();
  const long = P.direct(["recover", ok.sid, P.pair(ok).tp, ok.step, ok.stage, "10000"]);
  assert.equal(long.written, true, JSON.stringify(long));
  assert.ok(R.receiptExists(ok.sid, ok.step), "control: the receipt is written");
});
test("an unreadable receipt is discarded and denied as today, without recovery", () => {
  const s = at();
  const k = P.pair(s);
  R.writeReceiptRaw(s.sid, s.step, "{not json");
  const c = P.confirm(s, { tp: k.tp });
  assert.ok(c.denied && why(c).includes("(unreadable-receipt)"), show(c));
  assert.ok(!R.receiptExists(s.sid, s.step), "the broken receipt is discarded");
  assert.equal(c.calls, 0, show(c));
});
for (const fault of ["throw", "require-fails"]) {
  test(`the recovery module fails (${fault}): the no-receipt deny`, () => {
    const s = at();
    const k = P.pair(s);
    const before = P.markerTimes(s.sid);
    const c = P.confirm(s, { tp: k.tp, fault });
    failClosed(c, s, before);
  });
}
caseEnd();

caseBegin("recovery-is-not-replayed", "hooks/confirm-checkpoint/receipt-recovery.js");
test("after a recovered and spent receipt, the same CONFIRM again is refused by the log", () => {
  const s = at();
  const k = P.pair(s);
  const first = P.confirm(s, { tp: k.tp });
  assert.ok(first.dialog, `premise: recovered: ${show(first)}`);
  const second = P.confirm(s, { tp: k.tp });
  assert.ok(second.denied && why(second).includes("(no-receipt)") && why(second).includes(P.HINT), show(second));
  calledOnceUnwritten(second);
  assert.deepEqual(P.events(s.sid, s.step), ["write", "consume"], "no second write");
});
caseEnd();
