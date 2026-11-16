#!/usr/bin/env node
// tests/hooks/feature-2961-plan-presentation-turn-stop.js
// Tests: hooks/stop-confirm-plan-guard/settle.js, hooks/lib/presentation-turn.js, hooks/lib/plan-link-turn-check.js, hooks/lib/presentation-turn/block-reasons.js, hooks/lib/confirm-continuation.js
// Tags: TL2, hooks, stop-confirm-plan-guard, plan-presentation-turn, pre-confirm-audit, presentation-receipt, confirm-plan, scope:issue-specific
// TL3 gap: a real model turn that ends while the pre-confirm audit subagent is still running; here
// the transcript, the turn markers and the audit ledger are written by the fixture.
// #2961: the Stop guard asks for the plan-link line, writes the receipt and continues only in a plan
// presentation turn; a mid-turn gets none of them on any gate value, and unknown readiness keeps
// the legacy behaviour.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after: afterAll, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2961ps-"));
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

const SC = require("./feature-2961-plan-presentation-turn/stop-cases");
const UC = require("./feature-2961-plan-presentation-turn/undecidable-cases");

caseBegin("mid-turn-owes-no-link", "hooks/lib/plan-link-turn-check.js");
for (const gate of ["ON", "ERROR", "OFF"]) {
  test(`gate ${gate}: a mid-turn gets no plan-link block, no receipt, no continue`, () => SC.midTurn(gate));
}
caseEnd();

caseBegin("presentation-turn-unchanged", "hooks/stop-confirm-plan-guard/settle.js");
for (const gate of ["ON", "ERROR", "OFF"]) {
  test(`gate ${gate}: a plan presentation turn behaves as before`, () => SC.presentationTurn(gate));
}
caseEnd();

caseBegin("upstream-intent-rewrite", "hooks/lib/confirm-continuation.js");
test("an approved intent rewritten unchanged owes nothing; edited, it follows TR1", SC.upstreamIntent);
caseEnd();

caseBegin("unknown-readiness-is-legacy", "hooks/lib/presentation-turn/block-reasons.js");
test("corrupt state (every gate) and a throwing key computation keep the legacy Stop behaviour", SC.unknownIsLegacy);
caseEnd();

caseBegin("no-readinessFor-fallback", "hooks/lib/confirm-continuation.js");
test("presentedArtifacts* without readinessFor do not present a not-ready stage", UC.presentedFallback);
caseEnd();

caseBegin("undecidable-unwritten-filter", "hooks/stop-confirm-plan-guard/settle.js");
test("recordUndecidable neither records nor reports a not-ready stage", UC.undecidableUnwritten);
caseEnd();
