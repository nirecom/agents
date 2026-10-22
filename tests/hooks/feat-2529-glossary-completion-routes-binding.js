"use strict";
// Tests: hooks/workflow-state/glossary-check/record.js, hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/state-io/events.js, hooks/workflow-gate/glossary-record-checker.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, completion-boundary, completion-route, fingerprint, commit-gate, scope:issue-specific
// #2529 T6-1 (real routes), T6-4, T6-7: each stage's real completion route refuses without a
// glossary_check record; input 1 binds to R-A / R-S; an R-S record lives per commit. Split from
// feat-2529-glossary-completion.js for the per-test cap. Fixture: tests/lib/glossary-check-fixture.js;
// parts: ./feat-2529-glossary-completion/.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2529-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const boundary = require("./feat-2529-glossary-completion/boundary");
const fingerprint = require("./feat-2529-glossary-completion/fingerprint");
const lifecycle = require("./feat-2529-glossary-completion/lifecycle");

// Every part reports through F.check; an exception in one part is one failure, not an abort.
function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("each stage completion route refuses without a record and completes with a clean record", "hooks/workflow-state/state-io/events.js");
guarded("completion routes", boundary.routes);
caseEnd();

caseBegin("artifact input binds to the approval range for plans and to staged blobs for commits", "hooks/workflow-state/glossary-check/scope.js");
guarded("fingerprint binding", fingerprint.run);
caseEnd();

caseBegin("an R-S record is judged per commit across a multi-commit workflow", "hooks/workflow-gate/glossary-record-checker.js");
guarded("multi-commit lifecycle", lifecycle.run);
caseEnd();

restoreIsolation();
F.finish();
