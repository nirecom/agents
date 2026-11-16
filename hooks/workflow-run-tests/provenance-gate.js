"use strict";
// hooks/workflow-run-tests/provenance-gate.js — a test run without provenance (no verified
// tests/run-all.sh or test-runner emitter) is no run_tests evidence, so it leaves a recorded
// complete run_tests unchanged on every exit (#2011). Only the stdout route passes
// hasProvenance; the dispatch ingest (undefined) and both dispatch-unsettled routes stay out
// of the gate: an unsettled dispatch already has provenance and must not let an older result
// stand for it. Trust model: docs/architecture/claude-code/settings/hooks.md.

const { readState } = require("../workflow-state");

// The recorded projection, not the effective state: a masked complete is still complete here.
function recordedRunTestsStatus(sessionId) {
  const state = readState(sessionId);
  const rt = state && state.steps && state.steps.run_tests;
  return rt ? rt.status : undefined;
}

function holdsCompleteRunTests(r) {
  return r.hasProvenance === false && !r.unsettledStem
    && recordedRunTestsStatus(r.sessionId) === "complete";
}

// -> { head, detail } for a held failed exit; a held pass or exit 77 changed nothing to report.
function heldMessage(failedExit) {
  if (!failedExit) return null;
  return {
    head: "[run_tests] complete kept (provenance-absent run failed)",
    detail: "This test run has no tests/run-all.sh or test-runner worker provenance, so run_tests " +
      "stays complete. If the failure is a real regression, rerun /run-tests or emit " +
      "echo \"<<WORKFLOW_MARK_STEP_run_tests_pending>>\".",
  };
}

module.exports = { holdsCompleteRunTests, heldMessage, recordedRunTestsStatus };
