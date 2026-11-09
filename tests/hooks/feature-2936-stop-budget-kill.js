#!/usr/bin/env node
// tests/hooks/feature-2936-stop-budget-kill.js
// Tests: hooks/stop-confirm-plan-guard.js, hooks/stop-confirm-plan-guard/deadline.js, hooks/stop-confirm-plan-guard/undecidable.js, hooks/confirm-checkpoint.js, hooks/confirm-checkpoint/receipt-recovery.js, settings.json
// Tags: TL2, hooks, stop-guard, confirm-plan, presentation-receipt, hook-timeout, transcript-reader, kill-repro, scope:issue-specific
// TL3 gap: the host killing a real Stop hook at its 5 s timeout under parallel Stop-hook I/O load;
// here the budget is spent through STOP_CONFIRM_CONTINUE_T0_OFFSET_MS and the kill is a Stop that never ran.
// #2936 S11: on a ~40 MB transcript the Stop guard reads a bounded tail and ends within its budget,
// a spent budget goes straight to the undecidable path, a tool_use tail never continues and is not
// re-read whole, and a presentation whose Stop left no receipt is recovered at the next CONFIRM.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, before: beforeAll, test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2936bk-"));
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
const W0 = 256 * 1024;
let PREFIX = "";
beforeAll(() => { PREFIX = K.bigPrefix(SCRATCH, 40); });

const show = (r) => JSON.stringify({ rc: r.rc, ms: r.ms, reads: r.reads, out: String(r.out || "").slice(0, 300), err: String(r.err || "").slice(0, 300) });
// bounded(r, limit) -> the run read at most `limit` bytes of the transcript and never read it whole.
function bounded(r, limit) {
  assert.ok(r.reads, `the read-count preload reported: ${show(r)}`);
  assert.equal(r.reads.fullReads, 0, `no whole-file read of the transcript: ${show(r)}`);
  assert.ok(r.reads.bytes <= limit, `read ${r.reads.bytes} bytes, at most ${limit}: ${show(r)}`);
}
const noticeOnly = (r) => r.rc === 0 && typeof r.json.systemMessage === "string" && r.json.systemMessage !== "" && r.json.decision === undefined;

caseBegin("forty-mb-transcript-presentation-continues-within-budget", "hooks/stop-confirm-plan-guard.js");
test("a presentation turn after ~40 MB of history: receipt and continue within 3000 ms, a bounded read", () => {
  const s = R.sessionAt("outline", { tag: 9401 });
  const closing = K.closingOf(s);
  const tp = K.onPrefix(PREFIX, s.sid, K.presentation(s, closing));
  assert.ok(fs.statSync(tp).size > 39 * K.MB, "fixture: ~40 MB transcript");
  const r = K.guard(s, tp, { message: closing });
  assert.ok(r.continued, `continue: ${show(r)}`);
  assert.ok(R.receiptExists(s.sid, "outline"), "the receipt is written");
  assert.ok(r.ms <= 3000, `ended in ${r.ms} ms`);
  bounded(r, 4 * W0);
});
caseEnd();

caseBegin("spent-budget-goes-to-the-undecidable-path", "hooks/stop-confirm-plan-guard/deadline.js");
// An unflushed tail: the transcript's last text is not yet the final message the hook input names.
function unflushed(tag) {
  const s = R.sessionAt("outline", { tag });
  const tp = K.onPrefix(PREFIX, s.sid, K.presentation(s, "Writing the plan now."));
  return { s, tp, message: K.closingOf(s) };
}
test("offset 4000 and an unflushed last line: exit 0, no continue, the notice, fast", () => {
  const { s, tp, message } = unflushed(9411);
  const r = K.guard(s, tp, { message, offset: 4000 });
  assert.ok(!r.continued, `no continue: ${show(r)}`);
  assert.ok(noticeOnly(r), `exit 0 with only the notice: ${show(r)}`);
  assert.match(r.json.systemMessage, /outline/);
  assert.ok(r.ms < 2500, `ended in ${r.ms} ms`);
  bounded(r, 2 * W0);
});
test("offset 100000: no flush wait, straight to the undecidable path after the first window", () => {
  const { s, tp, message } = unflushed(9412);
  const r = K.guard(s, tp, { message, offset: 100000 });
  assert.ok(!r.continued, `no continue: ${show(r)}`);
  assert.ok(noticeOnly(r), `exit 0 with only the notice: ${show(r)}`);
  assert.ok(r.ms < 2000, `ended in ${r.ms} ms`);
  bounded(r, 2 * W0);
});
caseEnd();

caseBegin("tool-use-tail-never-continues-and-is-not-re-read", "hooks/stop-confirm-plan-guard/undecidable.js");
test("time left, the last entry a tool_use: no continue, and the tail is re-read only by its append", () => {
  const s = R.sessionAt("outline", { tag: 9421 });
  const closing = K.closingOf(s);
  const tp = K.onPrefix(PREFIX, s.sid, K.presentation(s, "Writing the plan now.", [R.A("a-tu", R.BASH("ls", "b9"))]));
  const r = K.guard(s, tp, { message: closing });
  assert.ok(!r.continued, `no continue on a tool_use tail: ${show(r)}`);
  assert.equal(r.rc, 0, show(r));
  bounded(r, 4 * W0);
});
caseEnd();

caseBegin("killed-stop-presentation-is-recovered-at-confirm", "hooks/confirm-checkpoint/receipt-recovery.js");
test("Stop never ran after the presentation: the next turn's CONFIRM echo reaches the dialog", () => {
  const s = R.sessionAt("outline", { tag: 9431 });
  const k = K.killedPair(s);
  const tp = R.writeTranscript(s.sid, k.entries);
  assert.ok(!R.receiptExists(s.sid, "outline"), "premise: no receipt");
  const e = R.echo(s.sid, "outline", { transcriptPath: tp, env: K.LANG_ENV });
  assert.ok(e.dialog, `the dialog follows: ${JSON.stringify(e.json).slice(0, 400)} ${e.err.slice(0, 200)}`);
});
test("a previous turn that presented nothing: the deny names a possible Stop timeout", () => {
  const s = R.sessionAt("outline", { tag: 9432 });
  const k = K.killedPair(s, { plain: true });
  const tp = R.writeTranscript(s.sid, k.entries);
  const e = R.echo(s.sid, "outline", { transcriptPath: tp, env: K.LANG_ENV });
  assert.ok(e.denied, `denied: ${JSON.stringify(e.json).slice(0, 400)}`);
  assert.match(JSON.stringify(e.json), /may have timed out/, "the deny carries the timeout hint");
  assert.ok(!R.receiptExists(s.sid, "outline"), "no receipt is made up");
  assert.equal(K.markersOf(s.sid).length, 1, "the markers are left as they were");
});
caseEnd();

caseBegin("stop-after-recovery-sees-only-its-own-turn", "hooks/confirm-checkpoint/receipt-recovery.js");
// recovered(tag, o) -> {s, k, tp}: turn N recovered at the CONFIRM echo of turn N+1; o.n1Marker also
// writes a marker in turn N+1 (after its opener) before the echo.
function recovered(tag, o) {
  const s = R.sessionAt("outline", { tag });
  const k = K.killedPair(s);
  if (o && o.n1Marker) {
    require(path.join(R.ROOT, "hooks/lib/turn-marker")).writeTurnMarker(s.sid, { session_id: s.sid, absPath: s.plan, suffix: s.stage, ts: k.base + 3000, created_at: k.at(3000) });
  }
  const tp = R.writeTranscript(s.sid, k.entries);
  const e = R.echo(s.sid, "outline", { transcriptPath: tp, env: K.LANG_ENV });
  assert.ok(e.dialog, `premise: the echo is recovered: ${JSON.stringify(e.json).slice(0, 300)}`);
  return { s, k, tp };
}
const nextTurn = (s, k, text) => R.writeTranscript(s.sid, [...k.entries, R.TR("e1", "u-tre1"), R.A("a-n1", R.T(text))]);
test("the next Stop (a plain turn N+1) ends without a plan-link block", () => {
  const { s, k } = recovered(9441);
  assert.deepEqual(K.markersOf(s.sid), [], "turn N's markers are consumed by the recovery");
  const text = "Approved; moving on to the detail plan.";
  const r = K.guard(s, nextTurn(s, k, text), { message: text });
  assert.equal(r.rc, 0, `no block: ${show(r)}`);
  assert.ok(!String(r.reason).includes("[confirm-plan] plan-link:"), show(r));
});
test("a marker written in turn N+1 is kept, and that Stop still judges it", () => {
  const { s, k } = recovered(9442, { n1Marker: true });
  const left = K.markersOf(s.sid);
  assert.equal(left.length, 1, `only turn N+1's marker is left: ${JSON.stringify(left)}`);
  assert.equal(left[0].created_at, k.at(3000));
  const text = "I rewrote the outline; more to come.";
  const r = K.guard(s, nextTurn(s, k, text), { message: text });
  assert.ok(r.blocked && r.reason.startsWith("[confirm-plan] plan-link:"), `the turn N+1 marker is judged as today: ${show(r)}`);
});
caseEnd();

caseBegin("hook-timeouts-match-settings", "settings.json");
// timeoutOf(script) -> the settings.json timeout (seconds) of the hook entry running `script`.
function timeoutOf(script) {
  const settings = JSON.parse(fs.readFileSync(path.join(R.ROOT, "settings.json"), "utf8"));
  const found = [];
  for (const groups of Object.values(settings.hooks || {})) {
    for (const g of groups) for (const h of g.hooks || []) if (String(h.command).includes(`/hooks/${script}"`)) found.push(h.timeout);
  }
  assert.equal(found.length, 1, `one settings entry runs ${script}: ${JSON.stringify(found)}`);
  return found[0];
}
test("STOP_HOOK_TIMEOUT_MS is the guard's settings timeout; CONFIRM_HOOK_TIMEOUT_MS is confirm-checkpoint's", () => {
  const D = R.tryRequire("hooks/stop-confirm-plan-guard/deadline.js");
  const RR = R.tryRequire("hooks/confirm-checkpoint/receipt-recovery.js");
  assert.equal(D.__missing, undefined, `deadline.js loads: ${D.__missing}`);
  assert.equal(RR.__missing, undefined, `receipt-recovery.js loads: ${RR.__missing}`);
  assert.equal(D.STOP_HOOK_TIMEOUT_MS, timeoutOf("stop-confirm-plan-guard.js") * 1000);
  assert.equal(RR.CONFIRM_HOOK_TIMEOUT_MS, timeoutOf("confirm-checkpoint.js") * 1000);
  assert.equal(typeof D.stopDeadlineAt, "function");
  assert.equal(typeof D.tailReadUntil, "function");
});
caseEnd();
