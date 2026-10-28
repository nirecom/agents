"use strict";
// tests/hooks/feature-2768-plan-sync-turn-commit.js
// Tests: hooks/lib/plan-sync/turn-trailer.js, hooks/lib/plan-sync/turn-commit.js, hooks/lib/plan-sync/commit-push.js, hooks/lib/plan-sync/git.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit
// #2768: one commit per user turn. Dispatcher only; the cases live in the sibling folder, which the other
// feature-2768-plan-sync-turn-*.js entry files share (each stays under the 180 s runner timeout), and
// use tests/lib/plan-sync-turn-fixture.js (local bare repos behind an ssh stub, no network).

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the real timing between the transcript's prompt record and UserPromptSubmit (the PROMPT_SKEW_MS premise)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F));

try {
caseBegin("trailer format and parse", "hooks/lib/plan-sync/turn-trailer.js");
  go("trailer");
caseEnd();
caseBegin("same-turn replacement R1-R4", "hooks/lib/plan-sync/commit-push.js");
  go("replace");
caseEnd();
caseBegin("overlayCommit parent and message function", "hooks/lib/plan-sync/git.js");
  go("replace", "runOverlay");
caseEnd();
} finally {
  F.finish();
  restore();
}
