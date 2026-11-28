"use strict";
// Tests: bin/workflow/lib/next-step/pm-audit-route.js, hooks/lib/pm-review-writer.js, hooks/workflow-gate/user-verified-pm-review.js, bin/workflow/lib/next-step/gate-mode.js
// Tags: TL2, scope:issue-specific, issue-3168, pm-session, pm-review, pre-confirm-audit, next-step-gate, batched-owner
// #3168: the plan stage gate asks the owners of every closed issue in one batched ownersOf call under the gate's
// own bound (GATE_OWNER_TIMEOUT_MS), keeps the decided candidates on a partial failure, and on a whole failure
// tells the user the class and its next action. The ask hint names WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN for every
// step; the PM writers judge by candidate membership while the hook path keeps the 2000 ms bound.
// TL3 gap (what this test does NOT catch):
// - real owner chain (ownersOf is stubbed here): tests/bin/feature-3168-pm-audit-route-real-owner.js to a fake gh; real GitHub untested;
// - a live model echoing the sentinel: TL3-hook-conventional-audit-chosen.js (RUN_TL3=on); a human approving the dialog untested.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
const D = require("./feature-2853-pre-confirm-audit/driver");
const PR = require("./feature-2853-pre-confirm-audit/pm-route-cases");
const P = require("./feature-3144-pm-review-writer/fixture");
const C = require("./feature-3168-pm-audit-route/cases");
PR.fx();
require(P.PRELOAD).install();
after(() => { restore(); });

const ctx = { test, assert, D, PR, FP: P.FP };

caseBegin("gate-batched-owner-lookup", "bin/workflow/lib/next-step/pm-audit-route.js");
C.registerGate(ctx);
caseEnd();

caseBegin("gate-hint-partial-and-whole-failure", "bin/workflow/lib/next-step/pm-audit-route.js");
C.registerAsk(ctx);
caseEnd();

caseBegin("gate-partial-candidate-pick", "bin/workflow/lib/next-step/pm-audit-route.js");
C.registerPick(ctx);
caseEnd();

caseBegin("pm-write-judged-by-candidate-membership", "hooks/lib/pm-review-writer.js");
C.registerWrite(ctx);
caseEnd();

caseBegin("ask-hint-every-step", "bin/workflow/lib/next-step/pm-audit-route.js");
C.registerHint(ctx);
caseEnd();

caseBegin("hook-path-owner-bound", "hooks/workflow-gate/user-verified-pm-review.js");
C.registerHookLimit(ctx);
caseEnd();
