"use strict";

const {
  computeReviewScopeFingerprint,
  evaluateReviewScopeFreshness,
} = require("./review-tests-evidence");

function resolveCurrentWsid() {
  const { resolveWorkflowSessionId } = require("../lib/resolve-workflow-session-id");
  try { return resolveWorkflowSessionId() || null; } catch (_) { return null; }
}

// Freshness reason → gate reason (#2327). Fail-closed: an unmeasurable or missing
// review scope blocks instead of trusting status=complete.
const FRESHNESS_BLOCK_REASONS = {
  unavailable: "fingerprint-unavailable",
  missing: "fingerprint-missing",
  stale: "stale-fingerprint",
};

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
      const { isBugfixSession } = require("../workflow-state/is-bugfix-session");
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
    const resolvedWsid = warnWsid ? resolveCurrentWsid() : null;
    const staleWarnings = !!(resolvedWsid && resolvedWsid !== warnWsid);
    // Missing stored wsid (legacy state), unresolvable wsid, or matching wsid →
    // keep the historical block. Stale prior-wsid warnings fall through.
    if (!staleWarnings) return { action: "block", reason: "warnings-pending" };
  }

  const freshness = evaluateReviewScopeFreshness(stepState, computeReviewScopeFingerprint(repoDir));
  if (freshness.reason === "no-tests") return { action: "skip" };
  if (!freshness.fresh) {
    return { action: "block", reason: FRESHNESS_BLOCK_REASONS[freshness.reason] || "fingerprint-unavailable" };
  }
  // Scope match → check wsid before approving (issue #924).
  const storedWsid = stepState && stepState.wsid;
  if (storedWsid) {
    const resolvedWsid = resolveCurrentWsid();
    if (resolvedWsid && resolvedWsid !== storedWsid) return { action: "block", reason: "stale-wsid" };
  }
  return { action: "skip" };
}

module.exports = { checkReviewTests };
