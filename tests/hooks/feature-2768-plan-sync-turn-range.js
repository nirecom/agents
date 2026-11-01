"use strict";
// tests/hooks/feature-2768-plan-sync-turn-range.js
// Tests: hooks/lib/plan-sync/turn-commit.js, hooks/lib/plan-sync/turn-trailer.js, hooks/lib/plan-sync/commit-push.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, turn-base, fail-closed
// #2768: where a turn starts (Plan-Sync-Turn-Base): appended chains, the 200-commit scan limit, and
// the same session's previous turn, the whole-history search past the scan, and an unreadable log failing closed
// (Turn-Base unknown). Dispatcher only; cases live in feature-2768-plan-sync-turn-commit/range.js and fail-closed.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - a real forge's compare page for the recorded base (a local bare repo stands in)
// - a real remote whose history outgrows the 200-commit scan during a turn (fast-import stands in)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)

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
  () => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F)));

caseBegin("turn base: appended chains, the 200-commit limit, the previous turn", "hooks/lib/plan-sync/turn-commit.js");
test("turn base: appended chains, the 200-commit limit, the previous turn", () => go("range"));
caseEnd();
caseBegin("fail closed: an unreadable log gives Turn-Base unknown and no turn range", "hooks/lib/plan-sync/turn-commit.js");
test("fail closed: an unreadable log gives Turn-Base unknown and no turn range", () => go("fail-closed"));
caseEnd();
caseBegin("fail closed: the trailer parser accepts exactly unknown as a Turn-Base", "hooks/lib/plan-sync/turn-trailer.js");
test("fail closed: the trailer parser accepts exactly unknown as a Turn-Base", () => go("fail-closed", "runTrailer"));
caseEnd();
