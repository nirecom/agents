"use strict";
// Tests: hooks/workflow-mark/emit.js
// Tags: TL1, hooks, workflow-mark, sentinel, output-channel, scope:issue-specific
// #2824 Step 1: renderOutput(messages, channel) is the pure function every workflow-mark output
// passes through. No message -> {} exit 0; INFO only -> the normal channel; any UNAPPLIED -> the
// strong channel (both "exit2" and "block-decision" are rendered here, channel passed explicitly);
// INFO + UNAPPLIED -> both texts, told apart by the [NOT APPLIED] prefix and a count summary.
// TL3 gap (what this test does NOT catch): whether Claude Code shows each channel to the model and
// on screen; that is tests/hooks/TL3-hook-posttooluse-output-channels.sh (RUN_TL3) plus a manual look.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2824-emit-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.writeFileSync(path.join(CFG, ".env"), "");
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.CONV_LANG = "japanese";
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const O = require("../lib/workflow-mark-output");
const PREFIX = O.PREFIX;
const INFO_TEXT = "[workflow] reset-from write_code: write_code and later reset to pending.";
const UNAPPLIED_TEXT = "workflow-mark: unknown step \"bogus\" for RESET_FROM; state NOT changed.";

function sinkWith(info, unapplied) {
  const s = O.loadEmit().createSink();
  for (const t of info) s.pushMessage(t);
  for (const t of unapplied) s.pushUnapplied(t);
  return s.messages;
}
function render(info, unapplied, channel) {
  const r = O.loadEmit().renderOutput(sinkWith(info, unapplied), channel);
  const stdout = typeof r.stdout === "string" ? (r.stdout.trim() === "" ? null : JSON.parse(r.stdout)) : r.stdout;
  return { stdout, stderr: String(r.stderr || ""), exitCode: r.exitCode };
}
const lineWith = (text, needle) => text.split("\n").find((l) => l.includes(needle)) || "";

caseBegin("emit-exports-severity-and-channel", "hooks/workflow-mark/emit.js");
test("emit.js exports SEVERITY, STRONG_CHANNEL, createSink, renderOutput, flush", () => {
  const E = O.loadEmit();
  assert.deepStrictEqual(E.SEVERITY, { INFO: "info", UNAPPLIED: "unapplied" });
  assert.ok(["exit2", "block-decision"].includes(E.STRONG_CHANNEL), `STRONG_CHANNEL=${E.STRONG_CHANNEL}`);
  for (const f of ["createSink", "renderOutput", "flush"]) assert.strictEqual(typeof E[f], "function", `${f} missing`);
  const s = E.createSink();
  s.pushMessage("a");
  s.pushUnapplied("b");
  assert.strictEqual(s.messages.length, 2, "sink keeps both messages");
});
caseEnd();

caseBegin("no-messages-render-empty-object", "hooks/workflow-mark/emit.js");
test("no message renders {} and exit 0 on both channels", () => {
  for (const ch of ["exit2", "block-decision"]) {
    const r = render([], [], ch);
    assert.strictEqual(r.exitCode, 0, ch);
    assert.deepStrictEqual(r.stdout, {}, ch);
    assert.strictEqual(r.stderr, "", ch);
  }
});
caseEnd();

caseBegin("info-only-uses-the-normal-channel", "hooks/workflow-mark/emit.js");
test("INFO only renders systemMessage + additionalContext, exit 0, no decision, no prefix", () => {
  const { getConvLangInjection } = require("../../hooks/lib/conv-lang");
  for (const ch of ["exit2", "block-decision"]) {
    const r = render([INFO_TEXT], [], ch);
    assert.strictEqual(r.exitCode, 0, ch);
    assert.strictEqual(r.stdout.decision, undefined, ch);
    assert.strictEqual(typeof r.stdout.systemMessage, "string", `${ch}: systemMessage`);
    const ac = O.additionalContextOf(r.stdout);
    assert.ok(ac.includes(INFO_TEXT), `${ch}: additionalContext ${JSON.stringify(ac)}`);
    assert.ok(ac.startsWith(getConvLangInjection()), `${ch}: additionalContext lacks the conv-lang injection`);
    if (r.stdout.hookSpecificOutput) assert.strictEqual(r.stdout.hookSpecificOutput.hookEventName, "PostToolUse");
    assert.ok(!JSON.stringify(r.stdout).includes(PREFIX) && !r.stderr.includes(PREFIX), `${ch}: INFO carries the prefix`);
  }
});
caseEnd();

caseBegin("unapplied-exit2-channel", "hooks/workflow-mark/emit.js");
test("UNAPPLIED on exit2: every message on stderr, exit 2, prefix on the refused line", () => {
  const r = render([], [UNAPPLIED_TEXT], "exit2");
  assert.strictEqual(r.exitCode, 2);
  assert.ok(lineWith(r.stderr, UNAPPLIED_TEXT).includes(PREFIX), `stderr ${JSON.stringify(r.stderr)}`);
  assert.ok(/1\b/.test(r.stderr.split("\n")[0]) && /not applied|unapplied/i.test(r.stderr.split("\n")[0]),
    `first stderr line is not the count summary: ${JSON.stringify(r.stderr.split("\n")[0])}`);
});
caseEnd();

caseBegin("unapplied-block-decision-channel", "hooks/workflow-mark/emit.js");
test("UNAPPLIED on block-decision: decision block, reason and additionalContext carry the refusal, exit 0", () => {
  const r = render([], [UNAPPLIED_TEXT], "block-decision");
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.stdout.decision, "block");
  assert.ok(lineWith(r.stdout.reason, UNAPPLIED_TEXT).includes(PREFIX), `reason ${JSON.stringify(r.stdout.reason)}`);
  assert.ok(O.additionalContextOf(r.stdout).includes(UNAPPLIED_TEXT), "additionalContext lacks the refusal");
  const head = String(r.stdout.systemMessage || r.stdout.reason).split("\n")[0];
  assert.ok(/1\b/.test(head) && /not applied|unapplied/i.test(head), `summary line ${JSON.stringify(head)}`);
});
caseEnd();

caseBegin("mixed-info-and-unapplied-are-told-apart", "hooks/workflow-mark/emit.js");
test("INFO + 2 UNAPPLIED: strong channel, both texts, prefix only on refused lines, count 2", () => {
  const second = "workflow-mark: REVIEW_TESTS_WARNINGS_ACCEPTED rejected — reason too short.";
  for (const ch of ["exit2", "block-decision"]) {
    const r = render([INFO_TEXT], [UNAPPLIED_TEXT, second], ch);
    const body = ch === "exit2" ? r.stderr : r.stdout.reason;
    assert.strictEqual(r.exitCode, ch === "exit2" ? 2 : 0, ch);
    if (ch === "block-decision") assert.strictEqual(r.stdout.decision, "block");
    for (const t of [UNAPPLIED_TEXT, second]) {
      const l = lineWith(body, t);
      assert.ok(l.indexOf(PREFIX) !== -1 && l.indexOf(PREFIX) < l.indexOf(t), `${ch}: prefix before ${t}: ${JSON.stringify(l)}`);
    }
    const info = lineWith(body, INFO_TEXT);
    assert.ok(info !== "" && !info.includes(PREFIX), `${ch}: INFO line missing or prefixed: ${JSON.stringify(body)}`);
    const head = String(ch === "exit2" ? r.stderr : (r.stdout.systemMessage || r.stdout.reason)).split("\n")[0];
    assert.ok(/\b2\b/.test(head) && /not applied|unapplied/i.test(head), `${ch}: summary ${JSON.stringify(head)}`);
  }
});
caseEnd();
