#!/usr/bin/env node
// tests/hooks/feature-2936-no-receipt-wording.js
// Tests: hooks/lib/no-receipt-hint.js, hooks/lib/confirm-continuation.js, hooks/confirm-checkpoint.js, hooks/stop-confirm-plan-guard.js, skills/_shared/confirm-plan.md
// Tags: TL2, hooks, confirm-checkpoint, confirm-plan, presentation-receipt, wording, scope:issue-specific
// TL3 gap: whether a live model reads the hint and checks the receipt log instead of re-presenting
// blindly; here only the texts the hooks and the shared procedure emit are pinned.
// #2936 S7: the no-receipt deny names a possible Stop timeout (in presentAgainReason and in the
// checkpoint's own fallback), the continue prompt claims the dialog only once the receipt is recorded,
// and confirm-plan.md's presentation sentence and recovery line say the same.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2936nw-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.PLAN_LANG;
process.env.CONV_LANG = "english";
process.chdir(SCRATCH);
afterAll(() => {
  process.chdir(os.tmpdir());
  restore();
  try { fs.rmSync(SCRATCH, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const R = require("./feature-2729-presentation-receipt/fixture");
const K = require("./feature-2936-stop-budget-kill/fixture");
const P = require("./feature-2936-receipt-recovery/fixture");

const NO_RECEIPT_TEXT = "no presentation of it is on record and the previous turn does not show one; " + P.HINT;
const CONTINUE_END = "— the presentation is recorded, so the approval dialog follows.";
const NEW_PRESENT = "The approval dialog follows once this presentation is recorded; if it does not appear, reply once you have reviewed the plan.";
const OLD_PRESENT = "The approval dialog follows this message; if it does not appear, reply once you have reviewed the plan.";
const RECOVERY_LINE = "When the Stop hook left no receipt, `confirm-checkpoint.js` records it from the previous turn only when that turn passes the same presentation check; otherwise the deny names a possible Stop timeout.";
const why = (c) => String((c.json.hookSpecificOutput || {}).permissionDecisionReason || "");

caseBegin("no-receipt-hint-module", "hooks/lib/no-receipt-hint.js");
test("NO_RECEIPT_HINT is the plan's sentence", () => {
  const H = R.tryRequire("hooks/lib/no-receipt-hint.js");
  assert.equal(H.__missing, undefined, `the module loads: ${H.__missing}`);
  assert.equal(H.NO_RECEIPT_HINT, P.HINT);
});
test("the hint carries no URL, no session id and no retry advice", () => {
  assert.doesNotMatch(P.HINT, /https?:\/\//);
  assert.doesNotMatch(P.HINT, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  assert.doesNotMatch(P.HINT, /retry|try again/i);
});
caseEnd();

caseBegin("present-again-reason-no-receipt", "hooks/lib/confirm-continuation.js");
for (const artifact of ["intent", "outline", "detail"]) {
  test(`presentAgainReason(${artifact}, no-receipt) names the previous turn and the hint`, () => {
    const CC = R.tryRequire("hooks/lib/confirm-continuation.js");
    assert.equal(CC.__missing, undefined, `the module loads: ${CC.__missing}`);
    const text = CC.presentAgainReason(artifact, "no-receipt");
    assert.ok(text.includes(`present the ${artifact} plan again (no-receipt): ${NO_RECEIPT_TEXT}.`), text);
  });
}
test("continueReason ends on the recorded-presentation sentence", () => {
  const CC = R.tryRequire("hooks/lib/confirm-continuation.js");
  const text = CC.continueReason("outline");
  assert.ok(text.includes('echo "<<WORKFLOW_CONFIRM_OUTLINE: {one-line summary}>>"'), text);
  assert.ok(text.endsWith(CONTINUE_END), text);
});
caseEnd();

caseBegin("checkpoint-fallback-carries-the-hint", "hooks/confirm-checkpoint.js");
test("confirm-continuation fails to load in confirm-checkpoint: the fallback no-receipt deny carries the hint", () => {
  const s = R.sessionAt("outline", { tag: 9701 });
  // Text after the link: the previous turn is no presentation, so the deny is no-receipt either way.
  const k = P.pair(s, { last: K.closingOf(s) + "\n\nAnything else?" });
  const c = P.confirm(s, { tp: k.tp, contFail: true });
  assert.ok(c.denied && !c.dialog, JSON.stringify(c.json));
  assert.ok(why(c).includes("CONFIRM_OUTLINE denied (no-receipt)"), `the fallback deny: ${why(c)}`);
  assert.ok(why(c).includes(P.HINT), `the fallback deny carries the hint: ${why(c)}`);
  assert.ok(!R.receiptExists(s.sid, s.step));
});
caseEnd();

caseBegin("confirm-plan-md-wording", "skills/_shared/confirm-plan.md");
const MD = () => fs.readFileSync(path.join(R.ROOT, "skills/_shared/confirm-plan.md"), "utf8").split(/\r?\n/);
test("the presentation sentence waits for the recorded presentation", () => {
  const text = MD().join("\n");
  assert.ok(text.includes(NEW_PRESENT), "the new presentation sentence");
  assert.ok(!text.includes(OLD_PRESENT), "the old sentence is gone");
});
test("the recovery line follows the mismatch line, as one line", () => {
  const lines = MD();
  const i = lines.findIndex((l) => l.startsWith("On a mismatch, or when it cannot verify"));
  assert.ok(i >= 0, "premise: the mismatch line");
  assert.equal(lines[i + 1], RECOVERY_LINE);
});
caseEnd();

caseBegin("guard-entry-reexports-record-undecidable", "hooks/stop-confirm-plan-guard.js");
test("the guard entry still exports recordUndecidable after the split", () => {
  const G = R.tryRequire("hooks/stop-confirm-plan-guard.js");
  assert.equal(G.__missing, undefined, `the entry loads: ${G.__missing}`);
  assert.equal(typeof G.recordUndecidable, "function");
});
caseEnd();
