"use strict";
// The evidence rule for a DECLARED run_tests completion (#2472), shared by every gate
// (sentinel / advance / mark): only a run records run_tests complete — record-run.js,
// the baseline record, the UNRUNNABLE accept — so a declaration is answered `already`
// on a recorded complete and refused otherwise. Read-only: never writes, never ingests.
// The refusal wording lives here once; mark-step-handler.js and the CLI relay it.

const SHOW_OUTCOME = "skills/run-tests/scripts/show-dispatch-outcome.sh";

const MESSAGES = {
  "run-evidence-ingest-pending": (sid) =>
    "run_tests NOT recorded — the /run-tests dispatch outcome has not been ingested yet. " +
    `Run \`bash ${SHOW_OUTCOME} --session ${sid}\` (its own PostToolUse ingests the outcome), ` +
    "then repeat the same operation.",
  "no-run-evidence": () =>
    "run_tests NOT recorded — a completion needs run evidence and none is recorded. " +
    "Re-run /run-tests; if failures remain, run bin/run-tests-baseline.",
};

// Lazy: dispatch-outcome.js requires workflow-state, which this module's caller is part of.
function hasPendingIngest(sessionId) {
  try {
    return require("../../workflow-run-tests/dispatch-outcome").settleDispatchOutcome(sessionId).ingest !== null;
  } catch (_) {
    return false;
  }
}

// -> { ok: true, already: true } | { ok: false, kind, message }
function checkRunTestsCompletion(sessionId, state) {
  const entry = state && state.steps ? state.steps.run_tests : null;
  if (entry && entry.status === "complete") return { ok: true, already: true };
  const kind = hasPendingIngest(sessionId) ? "run-evidence-ingest-pending" : "no-run-evidence";
  return { ok: false, kind, message: MESSAGES[kind](sessionId) };
}

module.exports = { checkRunTestsCompletion, RUN_EVIDENCE_KINDS: Object.keys(MESSAGES) };
