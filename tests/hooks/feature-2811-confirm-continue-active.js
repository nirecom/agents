#!/usr/bin/env node
// tests/hooks/feature-2811-confirm-continue-active.js
// Tests: hooks/stop-confirm-plan-guard.js, hooks/lib/presentation-receipt.js
// Tags: TL2, hooks, confirm-plan, stop-guard, presentation-receipt, continue-mark, scope:issue-specific
// TL3 gap: the hook runs as a spawned node process with a synthetic stop_hook_active input, not under a
// real claude -p; not covered: real Claude Code sending stop_hook_active=true after a continue, and the
// host rendering the exit-2 JSON systemMessage. Receipt unit cases: fix-2748-plan-name-unification.js.
// #2811: a text-only presentation continues once under stop_hook_active (N1), an undecidable tail
// continues only after a flushed tool_use-free re-read (N2), failed writes are notified (N3).
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2811-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.PLAN_LANG;process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const R = require("./feature-2729-presentation-receipt/fixture");
const N1 = require("./feature-2811-confirm-continue-active/n1-cases");
const N2 = require("./feature-2811-confirm-continue-active/n2-cases");
const N3 = require("./feature-2811-confirm-continue-active/n3-cases");
const C1 = require("./feature-2811-confirm-continue-active/c1-cases");

// check(name, ok, detail): one node:test test per verdict handed over by a case module.
function check(name, ok, detail) {
  test(name, () => {
    if (!ok) assert.fail(String(typeof detail === "string" ? detail : R.show(detail)).replace(/[\r\n]+/g, " ").slice(0, 400));
  });
}

caseBegin("decidable-active-continue-and-mark", "hooks/stop-confirm-plan-guard.js");
N1.continueAndMark(check);
caseEnd();

caseBegin("mark-caps-continue-to-once-per-plan", "hooks/lib/presentation-receipt.js");
N1.limitAndCarry(check);
caseEnd();

caseBegin("active-block-stays-suppressed", "hooks/stop-confirm-plan-guard.js");
N1.activeBlock(check);
caseEnd();

caseBegin("active-continue-holds-for-every-stage", "hooks/stop-confirm-plan-guard.js");
N1.perStage(check);
caseEnd();

caseBegin("undecidable-tail-continues-only-after-flushed-reread", "hooks/stop-confirm-plan-guard.js");
N2.reread(check);
caseEnd();

caseBegin("reread-tool-use-before-trailing-thinking-never-continues", "hooks/stop-confirm-plan-guard.js");
N2.rereadTrailing(check);
caseEnd();

caseBegin("flushed-reread-continue-holds-for-every-stage", "hooks/stop-confirm-plan-guard.js");
N2.rereadPerStage(check);
caseEnd();

caseBegin("undecidable-stage-without-grounds-never-continues", "hooks/stop-confirm-plan-guard.js");
N2.notContinued(check);
N2.otherStage(check);
caseEnd();

caseBegin("mark-write-failure-does-not-continue", "hooks/lib/presentation-receipt.js");
N3.markFailure(check);
caseEnd();

caseBegin("write-failures-are-notified-with-or-without-continue", "hooks/stop-confirm-plan-guard.js");
N3.receiptFailure(check);
N3.noticeWithContinue(check);
caseEnd();

caseBegin("stale-receipt-discarded-when-receipt-write-fails", "hooks/lib/presentation-receipt.js");
N3.staleReceiptFailure(check);
caseEnd();

caseBegin("block-continue-echo-chain-end-to-end", "hooks/stop-confirm-plan-guard.js");
C1.chain(check);
caseEnd();
