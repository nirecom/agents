"use strict";
// review_tests step lifecycle: completion token, warning clearance, invalidation.
// Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { assertValidSessionId, readState, markStep } = require("./core");

// record the staged-tests fingerprint at sentinel-emission time
function markReviewTestsComplete(sessionId, token, extraFields = {}) {
  if (typeof token !== "string" || token.length === 0) {
    throw new Error("markReviewTestsComplete: token must be a non-empty string");
  }
  const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  markStep(sessionId, "review_tests", "complete", { token, ...extraFields, wsid });
}

// Clear review_tests warnings while preserving the existing token/wsid.
// This is the state mutation for WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED.
// markStep does a full replace (no merge), so we must explicitly carry forward
// the existing token and wsid to avoid stale-token blocks in the gate.
function clearReviewTestsWarnings(sessionId, reason) {
  assertValidSessionId(sessionId); // explicit guard: readState's try-catch swallows errors
  const state = readState(sessionId);
  if (!state) return; // fail-open: nothing to clear
  const existing = (state.steps && state.steps.review_tests) || {};
  if (!existing.warnings_summary) return; // nothing to clear
  const token = existing.token || null;
  const wsid = existing.wsid || null;
  markStep(sessionId, "review_tests", "complete", {
    token,
    wsid,
    warnings_summary: null,
    warnings_accepted_reason: reason || null,
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

// re-pending the review_tests step; clears the recorded token
function invalidateReviewTests(sessionId, reason) {
  markStep(sessionId, "review_tests", "pending", {
    token: null,
    invalidate_reason: reason || null,
  });
}

module.exports = {
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  invalidateReviewTests,
};
