"use strict";
// Tests: hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/glossary-check/record.js, bin/check-glossary-drift, hooks/workflow-mark/glossary-accept-handler.js, hooks/workflow-gate/glossary-record-checker.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, fingerprint, scope:issue-specific
// #2529 T7-4 (invariant I-FP, input 4): a changed rule module alone stales a valid record + grant
// for all six stages through the ruleModules seam, and the old grant is not inherited. Split from
// feat-2529-glossary-fingerprint-inputs.js to fit the 180s per-test budget.
// Fixture: tests/lib/glossary-check-fixture.js; part: ./feat-2529-glossary-fingerprint-inputs/rules.js.
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
const rules = require("./feat-2529-glossary-fingerprint-inputs/rules");
after(() => {
  restoreIsolation();
  F.finish();
});

caseBegin("a changed rule module stales the record through the ruleModules seam", "hooks/workflow-state/glossary-check/scope.js");
test("a changed rule module stales the record through the ruleModules seam", () => noNewFailures(F.failureCount, () => {
  try {
    rules.run();
  } catch (e) {
    F.check("rules input ran to the end", false, (e && e.stack) || e);
  }
}));
caseEnd();
