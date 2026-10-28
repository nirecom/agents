"use strict";
// Tests: hooks/workflow-state/glossary-check/record.js, hooks/workflow-state/glossary-check/scope.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/effective-state.js, hooks/workflow-gate/glossary-record-checker.js, bin/check-glossary-drift
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, completion-boundary, fingerprint, commit-gate, scope:issue-specific
// #2529 T6-1..T6-3: the glossary_check completion predicate. The in-process write boundary
// refuses a ->complete of the 6 stages without a current, resolved record; sanctioned tokens and
// recorded completes are not re-judged; the early-gate snapshot self-repairs only with a valid
// record. Real routes, T6-4 and T6-7 live in feat-2529-glossary-completion-routes-binding.js
// (split for the per-test cap). Fixture: tests/lib/glossary-check-fixture.js; parts: ./feat-2529-glossary-completion/.
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
const sanctioned = require("./feat-2529-glossary-completion/sanctioned");

// Every part reports through F.check; an exception in one part is one failure, not an abort.
function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("completion boundary refuses missing stale unresolved records and accepts current ones for all six stages", "hooks/workflow-state/glossary-check/record.js");
guarded("boundary matrix", boundary.matrix);
caseEnd();

caseBegin("session-inherit and RESET_FROM completions are not judged by the glossary boundary", "hooks/workflow-state/glossary-check/record.js");
guarded("sanctioned tokens", sanctioned.sanctioned);
caseEnd();

caseBegin("a step already recorded complete is not reverted for a missing glossary record", "hooks/workflow-state/effective-state.js");
guarded("recorded complete", sanctioned.alreadyComplete);
caseEnd();

caseBegin("early-gate snapshot resolves an approved clarify_intent only with a valid glossary record", "hooks/workflow-state/effective-state.js");
guarded("self-repair", sanctioned.selfRepair);
caseEnd();

restoreIsolation();
F.finish();
