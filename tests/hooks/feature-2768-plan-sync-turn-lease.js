"use strict";
// tests/hooks/feature-2768-plan-sync-turn-lease.js
// Tests: hooks/lib/plan-sync/lease-push.js, hooks/lib/plan-sync/commit-push.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, lease-push
// #2768: the leased replacement push (lease miss, stale origin/main, a foreign push mid-write).
// Dispatcher only; cases live in feature-2768-plan-sync-turn-commit/lease.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the real timing between the transcript's prompt record and UserPromptSubmit (the PROMPT_SKEW_MS premise)
// - a real forge's porcelain and branch-protection wording (a local bare repo stands in)
// - races against a second real machine (the foreign push is injected through the ssh stub)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F));

try {
caseBegin("leased replacement push", "hooks/lib/plan-sync/lease-push.js");
  go("lease");
caseEnd();
caseBegin("a foreign push between tip read and replacement push misses the lease", "hooks/lib/plan-sync/lease-push.js");
  go("lease", "runRace");
caseEnd();
} finally {
  F.finish();
  restore();
}
