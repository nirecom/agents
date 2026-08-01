"use strict";
// review_tests step lifecycle: completion token, warning clearance, invalidation.
// Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { assertValidSessionId, readState, markStep } = require("./core");
const { appendEvents } = require("./events");

// record the staged-tests fingerprint at sentinel-emission time
function markReviewTestsComplete(sessionId, token, extraFields = {}) {
  if (typeof token !== "string" || token.length === 0) {
    throw new Error("markReviewTestsComplete: token must be a non-empty string");
  }
  const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  // The resolved workflow session id is a FALLBACK: an explicitly supplied
  // extraFields.wsid is the caller's own evidence and must win over the ambient probe.
  markStep(sessionId, "review_tests", "complete", { token, wsid, ...extraFields });
}

// Clear review_tests warnings. This is the state mutation for
// WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED.
//
// The token/wsid carry-forward is gone (#1733): annotations accumulate on the step
// instead of being replaced wholesale, so clearing one key can no longer drop the
// staged-tests fingerprint and cause a stale-token block. The "is there anything to
// clear?" decision is taken INSIDE the lock, so a concurrent warning append cannot
// be cleared by a decision made against a stale read.
function clearReviewTestsWarnings(sessionId, reason) {
  assertValidSessionId(sessionId); // explicit guard: readState's try-catch swallows errors
  if (!readState(sessionId)) return; // fail-open: nothing to clear
  appendEvents(sessionId, (events, current) => {
    const existing = (current && current.steps && current.steps.review_tests) || {};
    if (!existing.warnings_summary) return []; // nothing to clear
    return [
      {
        kind: "step_annotation",
        step: "review_tests",
        key: "warnings_summary",
        value: null,
        provenance: "observed",
        origin: "clear-review-tests-warnings",
      },
      {
        kind: "step_annotation",
        step: "review_tests",
        key: "warnings_accepted_reason",
        value: reason || null,
        provenance: "declared",
        origin: "clear-review-tests-warnings",
      },
    ];
  });
}

// Remove the review-loop terminal marker written by run-codex-review-loop.sh
// after a non-success terminal exit (issue #1361). Accepting the coverage gap
// ends the review, so the re-invoke guard must no longer fire. Fail-open.
function clearReviewTestsTerminalMarker(sessionId) {
  try {
    assertValidSessionId(sessionId);
    const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
    const markerPath = path.join(
      getWorkflowPlansDir(),
      `${sessionId}-test-review-terminal.txt`
    );
    fs.unlinkSync(markerPath);
  } catch (e) {
    // ENOENT (no marker) and any other failure are non-fatal.
  }
}

// re-pending the review_tests step; clears the recorded review evidence.
// Every cleared key is nulled EXPLICITLY (a tombstone per key) rather than relying
// on the step object being replaced — since #1733 nothing replaces it, so a key
// left unmentioned would survive the invalidation and re-authorize the gate.
function invalidateReviewTests(sessionId, reason) {
  markStep(sessionId, "review_tests", "pending", {
    token: null,
    wsid: null,
    warnings_summary: null,
    warnings_accepted_reason: null,
    invalidate_reason: reason || null,
  });
}

module.exports = {
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  invalidateReviewTests,
};
