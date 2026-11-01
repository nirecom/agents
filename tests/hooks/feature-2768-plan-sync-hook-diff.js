"use strict";
// tests/hooks/feature-2768-plan-sync-hook-diff.js
// Tests: hooks/show-plan-link.js, hooks/show-plan-link/turn-diff.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, show-plan-link, turn-diff
// #2768: the turn diff line rides after the unchanged plan-link block, and a progress-then-plan turn
// stays one commit. Dispatcher only; cases live in feature-2768-plan-sync-hook-paths/diff.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)
// - a real forge's compare page for the rendered link (a local bare repo stands in)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
after(() => {
  F.finish();
  restore();
});
const go = (name, fn) => noNewFailures(F.failureCount,
  () => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-hook-paths/${name}`)[fn || "run"](F)));

caseBegin("turn diff line follows the unchanged plan-link block", "hooks/show-plan-link/turn-diff.js");
test("turn diff line follows the unchanged plan-link block", () => go("diff"));
caseEnd();
caseBegin("renderTurnDiff units", "hooks/show-plan-link/turn-diff.js");
test("renderTurnDiff units", () => go("diff", "runUnits"));
caseEnd();
caseBegin("progress first, then a plan, in one turn commit", "hooks/show-plan-link.js");
test("progress first, then a plan, in one turn commit", () => go("diff", "runProgressFirst"));
caseEnd();
