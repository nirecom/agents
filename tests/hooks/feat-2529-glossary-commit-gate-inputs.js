"use strict";
// Tests: hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-gate/glossary-record-checker.js, hooks/workflow-state/glossary-check/record.js, hooks/workflow-state/glossary-check/scope.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-gate, commit-gate, glossary, glossary-check, fingerprint, scope:issue-specific
// #2529 T6-6, T7-6: a staged-blob swap and a glossary-only change both block
// glossary-check-stale at the commit gate with the changed component named. Split from
// feat-2529-glossary-commit-gate.js for the per-test cap; parts: ./feat-2529-glossary-commit-gate/.
// Also: a current record with an ungranted finding blocks until the matching grant is recorded.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2529-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const inputs = require("./feat-2529-glossary-commit-gate/inputs");
const unresolved = require("./feat-2529-glossary-commit-gate/unresolved");

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("commit gate blocks a staged blob swap and a glossary-only change naming the changed component", "hooks/workflow-gate/glossary-record-checker.js");
guarded("commit gate inputs", inputs.run);
caseEnd();

caseBegin("commit gate blocks a current record with an unresolved finding until the matching grant is recorded", "hooks/workflow-gate/commit-gate-steps.js");
guarded("commit gate unresolved findings", unresolved.run);
caseEnd();

restoreIsolation();
F.finish();
