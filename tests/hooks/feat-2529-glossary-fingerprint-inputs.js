"use strict";
// Tests: hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/glossary-check/record.js, bin/check-glossary-drift, hooks/workflow-mark/glossary-accept-handler.js, hooks/workflow-gate/glossary-record-checker.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, fingerprint, scope:issue-specific
// #2529 T7-1, T7-5 (invariant I-FP): one artifact byte alone stales a valid record + grant for all
// six stages, the stale detail names only that input, the old grant is not inherited, and only
// scope.js reads the inputs. To fit the 180s per-test budget the other inputs run elsewhere:
// T7-3 in feat-2529-glossary-fingerprint-intent-rows-{ra,rs}.js, T7-4 in
// feat-2529-glossary-fingerprint-rules.js, T7-2 in feat-2529-glossary-fingerprint-glossary{,-ra,-rs}.js.
// Fixture: tests/lib/glossary-check-fixture.js; parts: ./feat-2529-glossary-fingerprint-inputs/.
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
const artifact = require("./feat-2529-glossary-fingerprint-inputs/artifact");
const singleReader = require("./feat-2529-glossary-fingerprint-inputs/single-reader");
after(() => {
  restoreIsolation();
  F.finish();
});

// Every part reports through F.check; an exception in one part is one failure, not an abort.
function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("one changed artifact byte stales the record and the scanned range equals the approval range", "hooks/workflow-state/glossary-check/scope.js");
test("one changed artifact byte stales the record and the scanned range equals the approval range", () =>
  noNewFailures(F.failureCount, () => guarded("artifact input", artifact.run)));
caseEnd();

caseBegin("only scope.js reads the glossary artifact and intent inputs", "hooks/workflow-state/glossary-check/record.js");
test("only scope.js reads the glossary artifact and intent inputs", () =>
  noNewFailures(F.failureCount, () => guarded("single reader", singleReader.run)));
caseEnd();
