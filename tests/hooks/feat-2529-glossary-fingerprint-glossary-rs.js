"use strict";
// Tests: hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/glossary-check/record.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, fingerprint, scope:issue-specific
// #2529 T7-2 (invariant I-FP, input 2) for the R-S stages (tests, code, docs): each combined
// glossary change alone stales a valid record + grant, and the legacy switch is reported as
// glossary.legacy. Split from feat-2529-glossary-fingerprint-glossary.js to fit the 180s per-test
// budget; the R-A stages run in feat-2529-glossary-fingerprint-glossary-ra.js.
// Fixture: tests/lib/glossary-check-fixture.js; part: ./feat-2529-glossary-fingerprint-inputs/glossary.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2529-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const glossary = require("./feat-2529-glossary-fingerprint-inputs/glossary");
after(() => {
  restoreIsolation();
  F.finish();
});

caseBegin("each combined glossary change stales the record and the main worktree glossary is read", "hooks/workflow-state/glossary-check/scope.js");
test("each combined glossary change stales the record and the main worktree glossary is read", () => noNewFailures(F.failureCount, () => {
  try {
    glossary.runEachChange(F.RS_STAGES);
  } catch (e) {
    F.check("glossary input ran to the end", false, (e && e.stack) || e);
  }
}));
caseEnd();
