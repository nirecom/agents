"use strict";
// review_tests step lifecycle: review-scope manifest record, warning clearance,
// terminal-marker cleanup, write_code completion reopen, in_progress recovery after a
// terminal review exit (rc 2/6). Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { assertValidSessionId, readState, markStep } = require("./core");
// Called as events.appendEvents at call time (never destructured) so a wrapper
// installed on the module is honoured.
const events = require("./events");

const REVIEW_TESTS_REOPEN_REASONS = ["write-code-stale", "write-code-missing", "write-code-unavailable"];

// Accepts a plain { path: oid } map or a manifest result ({ ok?, v?, files }).
function manifestFiles(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  const wrapped = ("files" in input) && ("ok" in input || "v" in input);
  const files = wrapped ? input.files : input;
  return files && typeof files === "object" && !Array.isArray(files) ? files : null;
}

// The review-scope annotation fields: the per-file manifest, plus tombstones for the
// legacy token and the write_code reopen mark (a fresh review supersedes both).
function buildReviewScopeAnnotation(files) {
  return { review_scope_manifest: { v: 1, files: { ...files } }, token: null, reopen_reason: null };
}

function markReviewTestsComplete(sessionId, files, extraFields = {}) {
  const map = manifestFiles(files);
  if (!map) throw new Error("markReviewTestsComplete: files must be a { path: oid } object");
  const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  // The resolved workflow session id is a FALLBACK: an explicitly supplied
  // extraFields.wsid is the caller's own evidence and must win over the ambient probe.
  // A clean COMPLETE drops a past round's warning and acceptance reason; the WARNINGS path overrides
  // via extraFields. Recorded as observed by markStep (cleared by the handler), not declared.
  markStep(sessionId, "review_tests", "complete", { ...buildReviewScopeAnnotation(map), ...warningsTombstoneFields(), wsid, ...extraFields });
}

const CLEAR_OUTCOME = Object.freeze({
  RECOVERED: "recovered",
  RECOVERED_TERMINAL: "recovered-terminal",
  WARNINGS_CLEARED: "warnings-cleared",
  NOTHING_TO_CLEAR: "nothing-to-clear",
  MANIFEST_UNAVAILABLE: "manifest-unavailable",
  NO_STATE: "no-state",
});

function terminalMarkerPath(sessionId) {
  // Trust boundary: single-user local filesystem (NFR); forgeability risk accepted.
  assertValidSessionId(sessionId);
  const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
  return path.join(getWorkflowPlansDir(), `${sessionId}-test-review-terminal.txt`);
}

function hasReviewTerminalRecord(sessionId) {
  try {
    const line = fs.readFileSync(terminalMarkerPath(sessionId), "utf8").split("\n")[0].trim();
    return line === "2" || line === "6";
  } catch (e) {
    return false;
  }
}

function buildRecoveryEvents(origin, files, reason, ann) {
  const rann = (key, value, provenance) => ann(key, value, provenance, origin);
  const out = [{ kind: "step_status", step: "review_tests", status: "complete", provenance: "declared", origin }];
  for (const [key, value] of Object.entries(buildReviewScopeAnnotation(files))) out.push(rann(key, value, "observed"));
  out.push(rann("warnings_summary", null, "observed"), ...warningsAcceptedReasonEvents(reason, rann));
  return out;
}

// #2434 swap point: warningsAcceptedReasonEvents (record) and warningsTombstoneFields (clear)
// are the only places that know where the acceptance reason is recorded.
function warningsAcceptedReasonEvents(reason, ann) {
  return [ann("warnings_accepted_reason", reason || null, "declared")];
}

function warningsTombstoneFields() {
  return { warnings_summary: null, warnings_accepted_reason: null };
}

// WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED. The "anything to clear?" decision is taken
// INSIDE the lock; the clear, the reason and the current review-scope manifest (#2287)
// land in ONE batch, so a warning appended afterwards is never tombstoned.
// A write_code-reopened review_tests (#2482) is restored to complete in the same batch;
// without a manifest it stays reopened (fail-closed: the commit gate needs the manifest).
function clearReviewTestsWarnings(sessionId, reason, manifest) {
  assertValidSessionId(sessionId); // explicit guard: readState's try-catch swallows errors
  if (!readState(sessionId)) return CLEAR_OUTCOME.NO_STATE; // fail-open: nothing to clear
  const files = manifestFiles(manifest);
  const origin = "clear-review-tests-warnings";
  const ann = (key, value, provenance, o = origin) => ({ kind: "step_annotation", step: "review_tests", key, value, provenance, origin: o });
  let outcome = CLEAR_OUTCOME.NOTHING_TO_CLEAR;
  events.appendEvents(sessionId, (_events, current) => {
    outcome = CLEAR_OUTCOME.NOTHING_TO_CLEAR;
    const existing = (current && current.steps && current.steps.review_tests) || {};
    if (existing.status === "pending" && REVIEW_TESTS_REOPEN_REASONS.includes(existing.reopen_reason)) {
      if (!files) {
        outcome = CLEAR_OUTCOME.MANIFEST_UNAVAILABLE;
        return [];
      }
      const out = buildRecoveryEvents("accept-reopened-review-tests", files, reason, ann);
      outcome = CLEAR_OUTCOME.RECOVERED;
      return out;
    }
    if (existing.status === "in_progress" && hasReviewTerminalRecord(sessionId)) {
      if (!files) {
        outcome = CLEAR_OUTCOME.MANIFEST_UNAVAILABLE;
        return [];
      }
      const out = buildRecoveryEvents("accept-terminal-review-tests", files, reason, ann);
      outcome = CLEAR_OUTCOME.RECOVERED_TERMINAL;
      return out;
    }
    if (!existing.warnings_summary) return []; // nothing to clear
    const out = [ann("warnings_summary", null, "observed"), ...warningsAcceptedReasonEvents(reason, ann)];
    if (files) {
      for (const [key, value] of Object.entries(buildReviewScopeAnnotation(files))) out.push(ann(key, value, "observed"));
    }
    outcome = CLEAR_OUTCOME.WARNINGS_CLEARED;
    return out;
  });
  return outcome;
}

// Remove the review-loop terminal marker written by run-codex-review-loop.sh
// after a non-success terminal exit (issue #1361). Accepting the coverage gap
// ends the review, so the re-invoke guard must no longer fire. Fail-open.
function clearReviewTestsTerminalMarker(sessionId) {
  try {
    assertValidSessionId(sessionId);
    fs.unlinkSync(terminalMarkerPath(sessionId));
  } catch (e) {
    // ENOENT (no marker) and any other failure are non-fatal.
  }
}

function normalizeReopenDecision(d) {
  if (typeof d === "string") return REVIEW_TESTS_REOPEN_REASONS.includes(d) ? d : `write-code-${d}`;
  return d && d.reopen && typeof d.reason === "string" ? d.reason : null;
}

// write_code completion (#2327): record the completion-time review-scope snapshot on
// write_code and, when review_tests is complete and decide() says so, reopen it.
// Observed-evidence write outside the markStep registry (feature-1644): one builder
// under the lock; review_scope_manifest is kept so the second review can diff against it.
function recordWriteCodeCompletionScope(sessionId, snapshot, decide) {
  assertValidSessionId(sessionId);
  const snapFiles = snapshot && snapshot.ok !== false ? manifestFiles(snapshot) : null;
  const wcManifest = snapFiles ? { v: 1, files: { ...snapFiles } } : { v: 1, unavailable: true };
  const origin = "write-code-scope-drift";
  let reason = null;
  events.appendEvents(sessionId, (_events, current) => {
    reason = null;
    const out = [{ kind: "step_annotation", step: "write_code", key: "write_code_scope_manifest",
      value: wcManifest, provenance: "observed", origin }];
    const rt = (current && current.steps && current.steps.review_tests) || {};
    if (rt.status !== "complete" || typeof decide !== "function") return out;
    reason = normalizeReopenDecision(decide(rt));
    if (!reason) return out;
    out.push({ kind: "step_status", step: "review_tests", status: "pending", provenance: "observed", origin });
    out.push({ kind: "step_annotation", step: "review_tests", key: "reopen_reason", value: reason, provenance: "observed", origin });
    return out;
  });
  return { reopened: !!reason, reason };
}

module.exports = {
  REVIEW_TESTS_REOPEN_REASONS,
  CLEAR_OUTCOME,
  buildReviewScopeAnnotation,
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  recordWriteCodeCompletionScope,
};
