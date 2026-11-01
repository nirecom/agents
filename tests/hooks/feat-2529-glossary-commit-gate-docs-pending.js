"use strict";
// Tests: hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-gate/glossary-record-checker.js, hooks/workflow-state/glossary-check/record.js, hooks/workflow-state/glossary-check/scope.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-gate, commit-gate, glossary, glossary-check, fingerprint, worktree, pending-step, scope:issue-specific
// #2529 T6-5 for the docs stage (the slowest stage of the commit gate case, same case name as in
// feat-2529-glossary-commit-gate.js, which runs the other stages) and S-C1: a pending R-S step
// with staged stage targets is re-judged too. Split for the per-test cap.
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
const pending = require("./feat-2529-glossary-commit-gate/pending");
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
  noNewFailures(F.failureCount, () => guarded("commit gate cases docs stage", () => cases.runStages(["docs"]))));
caseEnd();

caseBegin("commit gate blocks a missing glossary record for a pending step whose stage targets are staged", "hooks/workflow-gate/commit-gate-steps.js");
test("commit gate blocks a missing glossary record for a pending step whose stage targets are staged", () =>
  noNewFailures(F.failureCount, () => guarded("commit gate pending", pending.run)));
caseEnd();
