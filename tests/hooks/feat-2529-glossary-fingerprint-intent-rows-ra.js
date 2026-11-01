"use strict";
// Tests: hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/glossary-check/record.js, bin/check-glossary-drift, hooks/workflow-mark/glossary-accept-handler.js, hooks/workflow-gate/glossary-record-checker.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, fingerprint, scope:issue-specific
// #2529 T7-3 (invariant I-FP, input 3) for the R-A stages (intent, outline, detail): each intent
// glossary row change alone stales a valid record + grant, an edit outside ## Glossary does not
// move intent_rows, and provenanceFingerprint binds the approval sha. Split from
// feat-2529-glossary-fingerprint-inputs.js to fit the 180s per-test budget; the R-S stages run in
// feat-2529-glossary-fingerprint-intent-rows-rs.js.
// Fixture: tests/lib/glossary-check-fixture.js; part: ./feat-2529-glossary-fingerprint-inputs/intent-rows.js.
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
const intentRows = require("./feat-2529-glossary-fingerprint-inputs/intent-rows");
after(() => {
  restoreIsolation();
  F.finish();
});

// Every section reports through F.check; an exception in one section is one failure, not an abort.
function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("each intent glossary row change stales the record and edits outside it do not", "hooks/workflow-state/glossary-check/scope.js");
test("each intent glossary row change stales the record and edits outside it do not", () =>
  noNewFailures(F.failureCount, () => guarded("intent_rows input", () => {
    intentRows.runRows(F.RA_STAGES);
    intentRows.runProvenance();
  })));
caseEnd();
