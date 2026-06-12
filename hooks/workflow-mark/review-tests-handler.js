"use strict";
// Issue #833 — handles WORKFLOW_REVIEW_TESTS_COMPLETE / WORKFLOW_REVIEW_TESTS_WARNINGS sentinels.
//
// COMPLETE form  : echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=<hex> [optional meta]>>"
//   Skill computes staged-tests fingerprint via computeStagedTestsToken and embeds it.
//   Handler extracts token from payload and records review_tests=complete.
// WARNINGS form  : echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=<hex> [warnings=N ...]>>"
//   Records review_tests=complete with warnings_summary so the gate can block until
//   warnings are resolved (gate checks warnings_summary field — C2 enforcement at gate layer).
// LOOKSLIKE form : echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS>>" (malformed — advisory only)
//
// Note: echo "<<WORKFLOW_MARK_STEP_review_tests_complete>>" is handled by
//   mark-step-handler.js which REJECTS it (review_tests requires a token payload).

const {
  REVIEW_TESTS_COMPLETE_RE_DQ,
  REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE,
  REVIEW_TESTS_WARNINGS_RE_DQ,
  REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");
const {
  markReviewTestsComplete,
  nextStepHint,
} = require("../lib/workflow-state");

function extractToken(payload) {
  const m = payload.match(/token=([A-Za-z0-9]+)/);
  return m ? m[1] : null;
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  const completeMatch = cmd.match(REVIEW_TESTS_COMPLETE_RE_DQ);
  const warningsMatch = cmd.match(REVIEW_TESTS_WARNINGS_RE_DQ);

  // --- WORKFLOW_REVIEW_TESTS_COMPLETE handler ---
  if (completeMatch) {
    const payload = completeMatch[1];
    const token = extractToken(payload);
    if (!token) {
      pushMessage(
        "workflow-mark: REVIEW_TESTS_COMPLETE rejected — missing token=<hex> in payload. " +
          "Re-emit: echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=<hex>>>\""
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — review_tests NOT recorded. ` +
          `Re-emit: echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=${token}>>"`
      );
      return true;
    }
    try {
      markReviewTestsComplete(sessionId, token);
      pushMessage(`[workflow] review_tests: complete (token: ${token}).`);
      const hint = nextStepHint("review_tests");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. review_tests NOT recorded.`
      );
    }
    return true;
  }

  // --- WORKFLOW_REVIEW_TESTS_WARNINGS handler ---
  // Records complete+warnings_summary. Gate blocks on warnings_summary (C2 enforcement).
  if (warningsMatch) {
    const payload = warningsMatch[1];
    const token = extractToken(payload);
    if (!sessionId) {
      signalFatal(
        "workflow-mark: could not resolve session_id — review_tests WARNINGS NOT recorded."
      );
      return true;
    }
    try {
      const usedToken = token || "warnings";
      markReviewTestsComplete(sessionId, usedToken, { warnings_summary: payload });
      pushMessage(
        `[workflow] /review-tests reported warnings: ${payload} — ` +
          "re-run /write-tests to address coverage gaps, then /review-tests again."
      );
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. review_tests WARNINGS NOT recorded.`
      );
    }
    return true;
  }

  // --- LOOKSLIKE (malformed COMPLETE) — advisory only ---
  if (REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      "workflow-mark: malformed WORKFLOW_REVIEW_TESTS_COMPLETE — " +
        "expected: echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=<hex>>>\""
    );
    return true;
  }

  // --- LOOKSLIKE (malformed WARNINGS) — advisory only ---
  if (REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      "workflow-mark: malformed WORKFLOW_REVIEW_TESTS_WARNINGS — " +
        "expected: echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=<hex> warnings=N>>>\""
    );
    return true;
  }

  return false;
}

module.exports = { handle };
