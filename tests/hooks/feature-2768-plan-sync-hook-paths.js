"use strict";
// tests/hooks/feature-2768-plan-sync-hook-paths.js
// Tests: hooks/show-plan-link.js, hooks/show-plan-link/turn-diff.js, hooks/lib/plan-sync/commit-push.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, show-plan-link, turn-diff
// #2768: every MUST path of the after-write hook (Write, session-progress Edit, assemble Bash) folds
// one user turn into one commit. Dispatcher only; cases live in feature-2768-plan-sync-hook-paths/fold.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - whether a real session records the prompt in the transcript before the model runs (the latest-prompt premise)
// - which transcript a real subagent hook input points to (the fixture transcript is synthetic)
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)

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

caseBegin("hook paths fold one turn into one commit", "hooks/show-plan-link.js");
test("hook paths fold one turn into one commit", () => go("fold"));
caseEnd();
caseBegin("one PostToolUse writes several plans and session-progress.md", "hooks/show-plan-link.js");
test("one PostToolUse writes several plans and session-progress.md", () => go("fold", "runMulti"));
caseEnd();
