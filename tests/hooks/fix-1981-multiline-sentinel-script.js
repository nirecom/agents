"use strict";
// Tests: hooks/workflow-mark.js, hooks/workflow-mark/line-sentinel.js, hooks/stop-sentinel-unapplied-notice/scan.js
// Tags: fix-1981, workflow-mark, sentinel, multi-statement, stop-backstop, session-close, single-quoted, reason-sentinel, midway, scope:issue-specific, TL2, pwsh-not-required, quoted-argument, comment-line, reset-from, subagent, escaped-quote, mid-word-hash
// #1981: a sentinel echo on its own line inside a multi-line script (session-close SC-6a) was not a
// sentinel for workflow-mark's splitter, so the step stayed pending with no word at all. The
// acceptance contract stays the same; the silent drop becomes a visible "NOT applied" refusal, and
// the Stop backstop counts such calls too (CPR-ORTH).
// TL3 gap (what this test does NOT catch):
// - the real Stop-hook process path: scan.js scanTurn is called in-process, never through the
//   registered Stop hook run by a live Claude Code host;
// - the report content sent to the real bin/supervisor-report is not inspected.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
const X = require("./feature-2824-sentinel-refusal-output/fixture").make();
const T = require("./feature-2877-sentinel-receipt-backstop/transcript");
const O = require("../lib/workflow-mark-output");
after(() => {
  X.cleanup();
  restoreIsolation();
});

const ROOT = path.resolve(__dirname, "..", "..");
const SCAN = require(path.join(ROOT, "hooks", "stop-sentinel-unapplied-notice", "scan.js"));
const LINE_SENTINEL = path.join(ROOT, "hooks", "workflow-mark", "line-sentinel.js");
const RECEIPT = require(path.join(ROOT, "hooks", "lib", "sentinel-receipt.js"));

const ECHO = 'echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"';
const MULTI = `node x\n${ECHO}`;
const IF_BLOCK = `if true; then\n  ${ECHO}\nfi`;
const NON_ECHO_MULTI = 'git log --oneline\ngit log --grep "<<WORKFLOW_MARK_STEP_x_complete>>"';
// A sentinel line that is not a statement: inside a multi-line quoted argument, or in a comment.
const QUOTED_ARG = "gh pr create --body 'intro\necho \"<<WORKFLOW_MARK_STEP_x_complete>>\"\nend'";
const COMMENT_LINE = 'node x\n# echo "<<WORKFLOW_MARK_STEP_x_complete>>"';
const RESET_MULTI = 'node x\necho "<<WORKFLOW_RESET_FROM_write_code: redo after review>>"';
const NOTICE = /multi-statement|standalone/i;
const statusOf = (sid) => ((X.F.S.readState(sid) || { steps: {} }).steps.final_report || {}).status;

function lineSentinel() {
  let lib;
  try { lib = require(LINE_SENTINEL); } catch (e) {
    throw new Error(`not implemented: hooks/workflow-mark/line-sentinel.js does not load (${String(e.message).split("\n")[0]})`);
  }
  if (typeof lib.hasLineSentinel !== "function") throw new Error("not implemented: hasLineSentinel is not exported");
  return lib.hasLineSentinel;
}

caseBegin("multi-line-script-sentinel-is-refused-visibly", "hooks/workflow-mark.js");
test("multi-line-script-sentinel-is-refused-visibly", () => {
  const sid = X.seedInit("m1");
  const r = X.mark(sid, MULTI, { projectDir: X.REPO, toolUseId: "toolu_m1" });
  assert.notStrictEqual(statusOf(sid), "complete", "the contract does not widen: the step must not be marked");
  const why = O.unappliedFailure(r, NOTICE);
  assert.strictEqual(why, null, `a dropped sentinel must be told as NOT applied: ${why}`);
  // The hook told this call itself, so it must leave a receipt and an outcome for the Stop backstop.
  const { receipts, outcomes } = RECEIPT.readReceipts(sid);
  assert.ok(receipts.has("toolu_m1"), `a receipt must be recorded for the refused multi-line call: ${JSON.stringify([...receipts])}`);
  assert.ok(outcomes.has("toolu_m1"), `an outcome must be recorded for the refused multi-line call: ${JSON.stringify([...outcomes])}`);
});
caseEnd();

caseBegin("if-block-then-echo-sentinel-is-refused-visibly", "hooks/workflow-mark.js");
test("if-block-then-echo-sentinel-is-refused-visibly", () => {
  const sid = X.seedInit("m2");
  const r = X.mark(sid, IF_BLOCK, { projectDir: X.REPO });
  assert.notStrictEqual(statusOf(sid), "complete");
  const why = O.unappliedFailure(r, NOTICE);
  assert.strictEqual(why, null, `a sentinel after then must be told as NOT applied: ${why}`);
});
caseEnd();

caseBegin("standalone-echo-still-completes-the-step", "hooks/workflow-mark.js");
test("standalone-echo-still-completes-the-step", () => {
  const sid = X.seedInit("m3");
  const r = X.mark(sid, ECHO, { projectDir: X.REPO });
  assert.strictEqual(r.code, 0, `rc=${r.code} stderr=${r.stderr}`);
  assert.strictEqual(statusOf(sid), "complete", `standalone echo must still apply: ${r.stdout} ${r.stderr}`);
  assert.ok(!NOTICE.test(r.stdout + r.stderr), `no multi-statement notice on a standalone echo: ${r.stdout}`);
  assert.ok(!(r.stdout + r.stderr).includes(O.PREFIX), `no NOT APPLIED on a standalone echo: ${r.stdout}`);
});
caseEnd();

caseBegin("sentinel-text-in-a-non-echo-command-stays-silent", "hooks/workflow-mark.js");
test("sentinel-text-in-a-non-echo-command-stays-silent", () => {
  const sid = X.seedInit("m4");
  const before = X.raw(sid);
  for (const cmd of ['git log --grep "<<WORKFLOW_MARK_STEP_x_complete>>"',
    'git log --oneline\ngit log --grep "<<WORKFLOW_MARK_STEP_x_complete>>"']) {
    const r = X.mark(sid, cmd, { projectDir: X.REPO });
    assert.strictEqual(O.silentFailure(r), null, `${JSON.stringify(cmd)}: ${O.silentFailure(r)}`);
  }
  assert.strictEqual(X.raw(sid), before, "state must not change");
});
caseEnd();

caseBegin("line-sentinel-helper-finds-only-a-sentinel-statement", "hooks/workflow-mark/line-sentinel.js");
test("line-sentinel-helper-finds-only-a-sentinel-statement", () => {
  const has = lineSentinel();
  for (const cmd of [MULTI, IF_BLOCK, `node x; ${ECHO}`, `for i in 1; do ${ECHO}; done`, `node x\r\n${ECHO}`]) {
    assert.strictEqual(has(cmd), true, `must find the sentinel statement in ${JSON.stringify(cmd)}`);
  }
  for (const cmd of ['git log --grep "<<WORKFLOW_MARK_STEP_x_complete>>"', NON_ECHO_MULTI, "node x\nnode y", "",
    'echo "WORKFLOW_MARK_STEP_final_report_complete"', QUOTED_ARG, COMMENT_LINE]) {
    assert.strictEqual(has(cmd), false, `no sentinel statement in ${JSON.stringify(cmd)}`);
  }
});
caseEnd();

caseBegin("sentinel-line-in-a-quoted-argument-or-comment-stays-silent", "hooks/workflow-mark.js");
test("sentinel-line-in-a-quoted-argument-or-comment-stays-silent", () => {
  const sid = X.seedInit("m5");
  const before = X.raw(sid);
  for (const cmd of [QUOTED_ARG, COMMENT_LINE]) {
    const r = X.mark(sid, cmd, { projectDir: X.REPO });
    assert.strictEqual(O.silentFailure(r), null, `${JSON.stringify(cmd)}: ${O.silentFailure(r)}`);
  }
  assert.strictEqual(X.raw(sid), before, "state must not change");
});
caseEnd();

caseBegin("multi-line-reset-from-sentinel-is-refused-visibly", "hooks/workflow-mark.js");
test("multi-line-reset-from-sentinel-is-refused-visibly", () => {
  const sid = X.seedInit("m6");
  const before = X.raw(sid);
  const r = X.mark(sid, RESET_MULTI, { projectDir: X.REPO });
  assert.strictEqual(X.raw(sid), before, "the contract does not widen: a multi-line RESET_FROM must not change state");
  const why = O.unappliedFailure(r, NOTICE);
  assert.strictEqual(why, null, `a dropped RESET_FROM must be told as NOT applied: ${why}`);
});
caseEnd();

// Every form isSentinel accepts on its own line counts — not only the double-quoted MARK_STEP.
caseBegin("line-sentinel-helper-finds-every-accepted-sentinel-form", "hooks/workflow-mark/line-sentinel.js");
test("line-sentinel-helper-finds-every-accepted-sentinel-form", () => {
  const has = lineSentinel();
  const forms = [
    "echo '<<WORKFLOW_MARK_STEP_final_report_complete>>'",
    'echo "<<WORKFLOW_RESET_FROM_write_code: redo after review>>"',
    'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>"',
    'echo "<<WORKFLOW_RESET_FROM_write_code: fix a; then b>>"',
  ];
  for (const form of forms) {
    const cmd = `node x\n${form}`;
    assert.strictEqual(has(cmd), true, `must find the sentinel statement in ${JSON.stringify(cmd)}`);
  }
});
caseEnd();

// Splitter edges: an escaped `\"` does not close a double quote, and a mid-word `#` is no comment.
caseBegin("line-sentinel-helper-honors-escaped-quotes-and-mid-word-hash", "hooks/workflow-mark/line-sentinel.js");
test("line-sentinel-helper-honors-escaped-quotes-and-mid-word-hash", () => {
  const has = lineSentinel();
  const SENT = 'echo "<<WORKFLOW_MARK_STEP_x_complete>>"';
  // The quote closes after b, so the `;` ends the statement and the sentinel stands alone.
  assert.strictEqual(has(`node "a\\"b"; ${SENT}`), true, "an escaped quote must not leave the quote open");
  // The `;` and the sentinel text sit inside one double-quoted argument: no sentinel statement.
  assert.strictEqual(has('node x "a\\";echo \\"<<WORKFLOW_MARK_STEP_x_complete>>\\""'), false,
    "a `;` inside a double quote with escaped quotes must not split");
  // `#` inside a word is not a comment, so the rest of the line survives.
  assert.strictEqual(has(`echo a#b; ${SENT}`), true, "a mid-word # must not start a comment");
});
caseEnd();

// A subagent's multi-line sentinel is refused with the subagent wording and still receipted.
caseBegin("subagent-multi-line-script-sentinel-is-refused-visibly", "hooks/workflow-mark.js");
test("subagent-multi-line-script-sentinel-is-refused-visibly", () => {
  const sid = X.seedInit("m7");
  const r = X.mark(sid, MULTI, { projectDir: X.REPO, toolUseId: "toolu_m7", agentId: "agent-f1981" });
  assert.notStrictEqual(statusOf(sid), "complete", "a subagent sentinel must not mark the step");
  const why = O.unappliedFailure(r, /NOT applied[\s\S]*main conversation/);
  assert.strictEqual(why, null, `a subagent multi-line sentinel must be told as NOT applied in the main conversation: ${why}`);
  const { receipts, outcomes } = RECEIPT.readReceipts(sid);
  assert.ok(receipts.has("toolu_m7"), `a receipt must be recorded for the refused subagent call: ${JSON.stringify([...receipts])}`);
  assert.ok(outcomes.has("toolu_m7"), `an outcome must be recorded for the refused subagent call: ${JSON.stringify([...outcomes])}`);
});
caseEnd();

// transcriptOf(sid, id, command) -> transcript lines of one turn with one Bash call and its result.
function transcriptOf(sid, id, command) {
  return T.toText([T.userPrompt(sid, "go"), ...T.call(sid, id, command)]).split("\n").filter((l) => l !== "");
}

caseBegin("stop-backstop-counts-a-multi-line-script-sentinel", "hooks/stop-sentinel-unapplied-notice/scan.js");
test("stop-backstop-counts-a-multi-line-script-sentinel", () => {
  const sid = "f1981-scan";
  // Guard: the scan itself sees an unreceipted standalone sentinel, so a 0 below is meaningful.
  const control = SCAN.scanTurn(transcriptOf(sid, "toolu_ctl", ECHO), { receipts: new Set(), outcomes: new Set() });
  assert.strictEqual(control.length, 1, `fixture: an unreceipted standalone sentinel is told: ${JSON.stringify(control)}`);

  const multi = SCAN.scanTurn(transcriptOf(sid, "toolu_multi", MULTI), { receipts: new Set(), outcomes: new Set() });
  assert.strictEqual(multi.length, 1, `a multi-line script sentinel must be told by the backstop: ${JSON.stringify(multi)}`);
  assert.strictEqual(multi[0].id, "toolu_multi");
  assert.strictEqual(multi[0].kind, SCAN.KIND.UNREACHED, `no receipt -> unreached: ${JSON.stringify(multi)}`);

  const done = SCAN.scanTurn(transcriptOf(sid, "toolu_ok", ECHO),
    { receipts: new Set(["toolu_ok"]), outcomes: new Set(["toolu_ok"]) });
  assert.deepStrictEqual(done, [], "an applied standalone sentinel is not told twice");
});
caseEnd();

caseBegin("stop-backstop-ignores-sentinel-text-in-a-non-echo-multi-line-command", "hooks/stop-sentinel-unapplied-notice/scan.js");
test("stop-backstop-ignores-sentinel-text-in-a-non-echo-multi-line-command", () => {
  const found = SCAN.scanTurn(transcriptOf("f1981-scan-nonecho", "toolu_nonecho", NON_ECHO_MULTI),
    { receipts: new Set(), outcomes: new Set() });
  assert.deepStrictEqual(found, [], `sentinel text in a non-echo statement is not a sentinel call: ${JSON.stringify(found)}`);
});
caseEnd();

caseBegin("stop-backstop-ignores-a-sentinel-line-in-a-quoted-argument-or-comment", "hooks/stop-sentinel-unapplied-notice/scan.js");
test("stop-backstop-ignores-a-sentinel-line-in-a-quoted-argument-or-comment", () => {
  for (const [id, cmd] of [["toolu_quoted", QUOTED_ARG], ["toolu_comment", COMMENT_LINE]]) {
    const found = SCAN.scanTurn(transcriptOf("f1981-scan-notstmt", id, cmd), { receipts: new Set(), outcomes: new Set() });
    assert.deepStrictEqual(found, [], `${JSON.stringify(cmd)} is not a sentinel call: ${JSON.stringify(found)}`);
  }
});
caseEnd();

caseBegin("stop-backstop-does-not-re-report-a-received-multi-line-call", "hooks/stop-sentinel-unapplied-notice/scan.js");
test("stop-backstop-does-not-re-report-a-received-multi-line-call", () => {
  const found = SCAN.scanTurn(transcriptOf("f1981-scan-rcv", "toolu_multi_rcv", MULTI),
    { receipts: new Set(["toolu_multi_rcv"]), outcomes: new Set(["toolu_multi_rcv"]) });
  assert.deepStrictEqual(found, [], `a multi-line call workflow-mark already told is not told twice: ${JSON.stringify(found)}`);
});
caseEnd();

caseBegin("stop-backstop-tells-a-multi-line-call-stopped-midway", "hooks/stop-sentinel-unapplied-notice/scan.js");
test("stop-backstop-tells-a-multi-line-call-stopped-midway", () => {
  const found = SCAN.scanTurn(transcriptOf("f1981-scan-mid", "toolu_multi_mid", MULTI),
    { receipts: new Set(["toolu_multi_mid"]), outcomes: new Set() });
  assert.strictEqual(found.length, 1, `a receipted multi-line call with no outcome must be told: ${JSON.stringify(found)}`);
  assert.strictEqual(found[0].id, "toolu_multi_mid");
  assert.strictEqual(found[0].kind, SCAN.KIND.MIDWAY, `receipt without outcome -> midway: ${JSON.stringify(found)}`);
});
caseEnd();
