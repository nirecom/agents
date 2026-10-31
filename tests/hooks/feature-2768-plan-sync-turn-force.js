"use strict";
// tests/hooks/feature-2768-plan-sync-turn-force.js
// Tests: hooks/lib/plan-sync/remote-state.js, hooks/lib/plan-sync/lease-push.js, hooks/lib/plan-sync/remote-url.js, hooks/lib/plan-sync/provision.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, remote-state
// #2768: a remote that refuses the replacement is learned, turn links follow, the URL builders, and
// re-provision or a URL change drops the learned state. Dispatcher only; cases live in
// feature-2768-plan-sync-turn-commit/force.js and invalidate.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - a real forge's refusal wording and compare/commit pages (a local bare repo stands in)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F));

try {
caseBegin("force refusal is learned and turn links follow", "hooks/lib/plan-sync/remote-state.js");
  go("force");
caseEnd();
caseBegin("compare and commit URL builders", "hooks/lib/plan-sync/remote-url.js");
  go("force", "runUrls");
caseEnd();
caseBegin("re-provision and URL change invalidate the learned state", "hooks/lib/plan-sync/provision.js");
  go("invalidate");
caseEnd();
} finally {
  F.finish();
  restore();
}
