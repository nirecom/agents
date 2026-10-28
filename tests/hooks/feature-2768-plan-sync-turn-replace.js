"use strict";
// tests/hooks/feature-2768-plan-sync-turn-replace.js
// Tests: hooks/lib/plan-sync/turn-commit.js, hooks/lib/plan-sync/commit-push.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit
// #2768: same-turn replacement R5-R7 (human commits, unchanged writes, the changed-rels list) and
// turnBaseOf. Dispatcher only; cases live in feature-2768-plan-sync-turn-commit/replace.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the real timing between the transcript's prompt record and UserPromptSubmit (the PROMPT_SKEW_MS premise)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)
// - a real forge's view of the replaced commit (a local bare repo stands in)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F));

try {
caseBegin("same-turn replacement R5-R7 and turnBaseOf", "hooks/lib/plan-sync/turn-commit.js");
  go("replace", "runMore");
caseEnd();
} finally {
  F.finish();
  restore();
}
