"use strict";
// Tests: hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-gate/glossary-record-checker.js, hooks/workflow-state/glossary-check/record.js, hooks/workflow-state/glossary-check/scope.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-gate, commit-gate, glossary, glossary-check, fingerprint, worktree, scope:issue-specific
// #2529 T6-5: the commit gate's step scan re-judges the review_tests / review_security /
// review_docs glossary_check record against the current staged set, for complete and skipped
// steps, in a linked worktree too, before every early continue. Split for the per-test cap:
// the docs stage and the pending step in -docs-pending.js, T6-6 / T7-6 in -inputs.js.
// Fixture: tests/lib/glossary-check-fixture.js; parts: ./feat-2529-glossary-commit-gate/.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2529-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const cases = require("./feat-2529-glossary-commit-gate/cases");
after(() => {
  restoreIsolation();
  F.finish();
});

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("commit gate blocks missing stale and unavailable glossary records for complete skipped and worktree steps", "hooks/workflow-gate/commit-gate-steps.js");
test("commit gate blocks missing stale and unavailable glossary records for complete skipped and worktree steps", () =>
  noNewFailures(F.failureCount, () => guarded("commit gate cases", () => {
    cases.runStages(F.RS_STAGES.filter((s) => s !== "docs"));
    cases.runCommitShapes();
  })));
caseEnd();
