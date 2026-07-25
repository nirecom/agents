"use strict";

const { computeStagedTestsToken } = require("./review-tests-evidence");

/**
 * Evaluate the review_tests step in the workflow gate.
 * Returns { action: 'not_handled' | 'skip' | 'block', reason?: string }
 *   'not_handled' — caller should proceed with generic step logic
 *   'skip'        — gate should continue (step approved)
 *   'block'       — gate should push step to incomplete; reason is the incompleteReasons key
 */
function checkReviewTests(step, stepState, opts) {
  if (step !== "review_tests") return { action: "not_handled" };

  const { docsOnly, writeTestsEvidenceBypassed, repoDir, sessionId } = opts;
  const status = stepState ? stepState.status : "pending";

  // docs-only short-circuit must come before BUGFIX check so that a docs-only
  // BUGFIX session is not mis-blocked on review_tests (no tests expected).
  if (docsOnly) return { action: "skip" };
  // D2 defense (#1147 T0-A): BUGFIX sessions must complete review_tests — skip is not allowed.
  if (status === "skipped") {
    try {
      const { isBugfixSession } = require("../lib/workflow-state/is-bugfix-session");
      if (isBugfixSession({ sessionId })) {
        return { action: "block", reason: null };
      }
    } catch (_) {}
    return { action: "skip" };
  }
  if (status !== "complete") {
    // Symmetric evidence bypass: when write_tests itself was bypassed by
    // staged tests/, review_tests shares the same evidence (issue #833).
    if (writeTestsEvidenceBypassed) return { action: "skip" };
    return { action: "block", reason: null };
  }
  // status === "complete": unresolved warnings block (C2 enforcement), but only
  // when they belong to the current workflow session id (issue #924). Warnings
  // recorded under a prior wsid are stale and must not block this wsid's commit.
  if (stepState && stepState.warnings_summary) {
    const warnWsid = stepState.wsid;
    let staleWarnings = false;
    if (warnWsid) {
      const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
      let resolvedWsid = null;
      try { resolvedWsid = resolveWorkflowSessionId() || null; } catch (_) {}
      if (resolvedWsid && resolvedWsid !== warnWsid) staleWarnings = true;
    }
    // Missing stored wsid (legacy state), unresolvable wsid, or matching wsid →
    // keep the historical block. Stale prior-wsid warnings fall through to the
    // token/wsid checks below.
    if (!staleWarnings) return { action: "block", reason: "warnings-pending" };
  }

  // Validate stored token against freshly computed staged-tests fingerprint.
  const stagedToken = computeStagedTestsToken(repoDir);
  const storedToken = stepState && stepState.token;
  // No staged tests → no fingerprint surface → trust status=complete.
  if (stagedToken == null) return { action: "skip" };
  // No stored token but status=complete → legacy / pre-token state. Trust assertion.
  if (!storedToken) return { action: "skip" };

  // Token match → check wsid before approving (issue #924).
  if (stagedToken === storedToken) {
    const storedWsid = stepState && stepState.wsid;
    if (storedWsid) {
      const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
      let resolvedWsid = null;
      try { resolvedWsid = resolveWorkflowSessionId() || null; } catch (_) {}
      if (resolvedWsid && resolvedWsid !== storedWsid) {
        return { action: "block", reason: "stale-wsid" };
      }
    }
    return { action: "skip" };
  }

  // Token mismatch → stale review → re-gate.
  return { action: "block", reason: "stale-token" };
}

module.exports = { checkReviewTests };
