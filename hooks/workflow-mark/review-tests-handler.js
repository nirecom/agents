"use strict";
// Issue #833 / #2327 — WORKFLOW_REVIEW_TESTS_COMPLETE / _WARNINGS / _WARNINGS_ACCEPTED sentinels.
//
// COMPLETE : echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint={hex} [meta]>>"
// WARNINGS : echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint={hex} [warnings=N ...]>>"
//   The handler recomputes the review-scope manifest itself and records it only when
//   its digest equals the payload fingerprint; mismatch / no payload / calc error →
//   signalFatal, nothing written. WARNINGS also stores warnings_summary (gate C2 block).
// Note: <<WORKFLOW_MARK_STEP_review_tests_complete>> is REJECTED by mark-step-handler.js.

const {
  REVIEW_TESTS_COMPLETE_RE_DQ,
  REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE,
  REVIEW_TESTS_WARNINGS_RE_DQ,
  REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE,
  REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ,
  REVIEW_TESTS_WARNINGS_ACCEPTED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");
const {
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  markStep,
  readState,
} = require("../workflow-state");
const { hasCompletionEvidence } = require("../workflow-state/evidence-resolver");
const {
  computeReviewScopeManifest,
  fingerprintOfManifest,
} = require("../workflow-gate/review-tests-evidence");

const RESTART_HINT = "Re-run /review-tests from RT-5a (recompute the fingerprint, then re-emit).";

function extractFingerprint(payload) {
  const m = payload.match(/fingerprint=([0-9a-f]{16})/);
  return m ? m[1] : null;
}

// The review scope the commit gate will verify: the hook's tool-input cwd, else
// the session-bound linked worktree.
function computeHandlerManifest(sessionId, repoCwd) {
  let dir = repoCwd || null;
  if (!dir) {
    const { resolveSessionWorktreePath } = require("../workflow-state/resolve-worktree-path");
    dir = resolveSessionWorktreePath(sessionId);
  }
  if (!dir) return { ok: false, error: "no worktree resolved" };
  const { toWindowsPath } = require("../lib/branch-diff");
  return computeReviewScopeManifest(toWindowsPath(dir));
}

// Returns the verified files map, or null after signalling fatal.
function verifyFingerprint(label, payload, ctx) {
  const { sessionId, signalFatal, repoCwd } = ctx;
  const fp = extractFingerprint(payload);
  if (!fp) {
    signalFatal(`workflow-mark: ${label} rejected — missing fingerprint={hex} in payload. ${RESTART_HINT}`);
    return null;
  }
  if (!sessionId) {
    signalFatal(`workflow-mark: could not resolve session_id — review_tests ${label} NOT recorded. ${RESTART_HINT}`);
    return null;
  }
  const manifest = computeHandlerManifest(sessionId, repoCwd);
  if (!manifest.ok) {
    signalFatal(`workflow-mark: ${label} rejected — review-scope fingerprint unavailable (${manifest.error}). ${RESTART_HINT}`);
    return null;
  }
  const own = fingerprintOfManifest(manifest.files);
  if (own !== fp) {
    signalFatal(`workflow-mark: ${label} rejected — fingerprint=${fp} does not match the staged review scope (${own}). ${RESTART_HINT}`);
    return null;
  }
  return manifest.files;
}

function backfillWriteTests(sessionId, repoCwd, pushMessage) {
  try {
    const st = readState(sessionId);
    if (!st) return;
    if (((st.steps && st.steps.write_tests) || {}).status !== "pending") return;
    if (!hasCompletionEvidence("write_tests", sessionId, { repoDir: repoCwd })) return;
    markStep(sessionId, "write_tests", "complete");
    pushMessage("[workflow] write_tests: complete (auto-backfilled from review_tests evidence).");
  } catch (e) {
    pushMessage(`[workflow] write_tests backfill warning: ${e.message} — review_tests already recorded.`);
  }
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal, repoCwd } = ctx;

  const completeMatch = cmd.match(REVIEW_TESTS_COMPLETE_RE_DQ);
  const warningsMatch = cmd.match(REVIEW_TESTS_WARNINGS_RE_DQ);

  // --- WORKFLOW_REVIEW_TESTS_COMPLETE handler ---
  if (completeMatch) {
    const files = verifyFingerprint("REVIEW_TESTS_COMPLETE", completeMatch[1], ctx);
    if (!files) return true;
    try {
      markReviewTestsComplete(sessionId, files);
      pushMessage(`[workflow] review_tests: complete (fingerprint: ${fingerprintOfManifest(files)}).`);
      backfillWriteTests(sessionId, repoCwd, pushMessage);
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
    const files = verifyFingerprint("REVIEW_TESTS_WARNINGS", payload, ctx);
    if (!files) return true;
    try {
      markReviewTestsComplete(sessionId, files, { warnings_summary: payload });
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

  // --- WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED handler ---
  // Clears warnings_summary and re-records the current review-scope manifest (#2287)
  // so the gate unblocks /write-code.
  const acceptedMatch = cmd.match(REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ);
  if (acceptedMatch) {
    const reason = acceptedMatch[1];
    if (reason.replace(/\s/g, "").length < 3) {
      pushMessage(
        "workflow-mark: REVIEW_TESTS_WARNINGS_ACCEPTED rejected — reason too short. " +
          "Re-emit: echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>\""
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        "workflow-mark: could not resolve session_id — REVIEW_TESTS_WARNINGS_ACCEPTED NOT recorded."
      );
      return true;
    }
    try {
      const manifest = computeHandlerManifest(sessionId, repoCwd);
      clearReviewTestsWarnings(sessionId, reason, manifest.ok ? manifest : null);
      // #1361: accepting the gap ends this review — drop the re-invoke guard marker.
      clearReviewTestsTerminalMarker(sessionId);
      pushMessage(
        "[workflow] REVIEW_TESTS_WARNINGS_ACCEPTED: warnings cleared — /write-code unblocked."
      );
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. warnings NOT cleared.`
      );
    }
    return true;
  }

  // --- LOOKSLIKE (malformed WARNINGS_ACCEPTED) — advisory only ---
  if (REVIEW_TESTS_WARNINGS_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      "workflow-mark: malformed WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED — " +
        "expected: echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>\""
    );
    return true;
  }

  // --- LOOKSLIKE (malformed COMPLETE) — advisory only ---
  if (REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      "workflow-mark: malformed WORKFLOW_REVIEW_TESTS_COMPLETE — " +
        "expected: echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint={hex}>>\""
    );
    return true;
  }

  // --- LOOKSLIKE (malformed WARNINGS) — advisory only ---
  if (REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      "workflow-mark: malformed WORKFLOW_REVIEW_TESTS_WARNINGS — " +
        "expected: echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint={hex} warnings=N>>\""
    );
    return true;
  }

  return false;
}

module.exports = { handle };
