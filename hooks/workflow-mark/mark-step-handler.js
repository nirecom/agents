"use strict";
// Handles WORKFLOW_MARK_STEP_<step>_complete sentinels. Validates the step name
// against VALID_STEPS and marks it complete. Rejects forbidden manual-mark steps
// (user_verification, write_tests, docs) that must be emitted via their own paths.

const { MARKER_RE_DQ, MARKER_RE_SQ } = require("../lib/sentinel-patterns");
const { VALID_STEPS, markStep } = require("../lib/workflow-state");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  const markMatch = cmd.match(MARKER_RE_DQ) || cmd.match(MARKER_RE_SQ);

  // --- MARK_STEP handler ---
  if (markMatch) {
    const [, stepName, status] = markMatch;

    // user_verification must go through the WORKFLOW_USER_VERIFIED echo path
    if (stepName === "user_verification") {
      pushMessage(
        `workflow-mark: user_verification NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
          `Ask the user for commit approval via: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>" ` +
          `(reason: >=3 non-space chars, no '>', not a placeholder)`
      );
      return true;
    }

    // review_tests must go through the dedicated REVIEW_TESTS_COMPLETE / WARNINGS
    // sentinel path (which carries a staged-tests-snapshot token). Manual
    // MARK_STEP would bypass the stale-token anti-bypass guard.
    if (stepName === "review_tests") {
      pushMessage(
        `workflow-mark: review_tests NOT recorded — MARK_STEP not accepted for this step. ` +
          `Invoke /review-tests skill (which auto-computes the staged-tests token) ` +
          `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>"`
      );
      return true;
    }

    // write_tests and docs must go through evidence (staged files) or NOT_NEEDED sentinels
    if (stepName === "write_tests") {
      pushMessage(
        `workflow-mark: write_tests NOT recorded — MARK_STEP not accepted for this step. ` +
          `Stage tests/ changes (run /write-tests then git add tests/) ` +
          `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"` +
          ` (reason must be >=3 non-space chars, no '>', not a placeholder)`
      );
      return true;
    }
    if (stepName === "docs") {
      pushMessage(
        `workflow-mark: docs NOT recorded — MARK_STEP not accepted for this step. ` +
          `Run /update-docs, then satisfy either route: ` +
          `(a) stage docs/ or *.md files (git add docs/ ...); or ` +
          `(b) inside a linked worktree, ensure WORKTREE_NOTES.md ` +
          `## History Notes / ## Changelog Notes contain real bullets ` +
          `(not just "- (none)") — staging path introduced by #436 / #484. ` +
          `No MARK_STEP skip path.`
      );
      return true;
    }

    // Validate step name (regex already constrains status values)
    if (!VALID_STEPS.includes(stepName)) {
      pushMessage(`workflow-mark: unknown step "${stepName}" in marker — ignored.`);
      return true;
    }

    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — step "${stepName}" NOT recorded. ` +
          `Commit gate will block. Re-run: ` +
          `echo "<<WORKFLOW_MARK_STEP_${stepName}_${status}>>"`
      );
      return true;
    }

    try {
      markStep(sessionId, stepName, status);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. Step "${stepName}" NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
