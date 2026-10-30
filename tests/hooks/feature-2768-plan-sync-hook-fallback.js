"use strict";
// tests/hooks/feature-2768-plan-sync-hook-fallback.js
// Tests: hooks/show-plan-link.js, hooks/lib/plan-sync/commit-push.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, show-plan-link
// #2768: a stale turn id or an unusable session falls back to an append, and a force-refusing remote
// is learned by real hook runs. Dispatcher only; cases live in feature-2768-plan-sync-hook-paths/fallback.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - whether a real session records the prompt in the transcript before the model runs (the latest-prompt premise)
// - a real forge's branch-protection refusal wording (receive.denyNonFastForwards stands in)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-hook-paths/${name}`)[fn || "run"](F));

try {
caseBegin("stale turn id and unusable session fall back to an append", "hooks/lib/plan-sync/commit-push.js");
  go("fallback");
caseEnd();
caseBegin("a force-refusing remote is learned by real hook runs", "hooks/lib/plan-sync/commit-push.js");
  go("fallback", "runForce");
caseEnd();
} finally {
  F.finish();
  restore();
}
