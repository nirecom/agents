"use strict";
// Handles WORKFLOW_MARK_STEP_<step>_complete sentinels. Validates the step name
// against VALID_STEPS and marks it complete. Always refuses the REFUSED_MARK_STEPS
// table's steps; write_tests and the run_tests skip are refused only without evidence.

const { MARKER_RE_DQ, MARKER_RE_SQ } = require("../lib/sentinel-patterns");
const { VALID_STEPS } = require("../workflow-state");
const { hasCompletionEvidence } = require("../workflow-state/evidence-resolver");
const { confirmSentinelFor } = require("../workflow-state/completion-approval");
// #1644: the declared-class single writer. It owns the state write itself, the
// approval invariant and the workflow_init downstream reset; this handler keeps
// only the sentinel-specific wording.
const { recordStepVerdict } = require("../workflow-state/record-step-verdict");
const { formatReviewTestsReopenNotice } = require("../workflow-state/review-tests-reopen");
// #1644: MARK_STEP_* is settings.json `allow` (freely emittable), so once
// run_tests became skippable this door must verify the docs-only fact itself.
// Single owner of the predicate — never restate the allowlist here.
const { isDocsOnlyStaged } = require("../workflow-gate/staged-evidence");
const { RUN_EVIDENCE_KINDS } = require("../workflow-state/record-step-verdict/run-tests-evidence");

// Refusals whose wording record-step-verdict already owns: relayed as-is.
const RELAYED_KINDS = ["no-release-evidence", "glossary-incomplete", ...RUN_EVIDENCE_KINDS];

// Steps MARK_STEP never records, whatever the status: each has its own door.
// user_verification: the USER_VERIFIED echo. review_tests: the fingerprinted
// review-tests sentinel (MARK_STEP would bypass the stale-fingerprint guard).
// docs: staged docs/ or WORKTREE_NOTES bullets.
const REFUSED_MARK_STEPS = Object.freeze({
  user_verification:
    `workflow-mark: user_verification NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
    `Ask the user for commit approval via: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" ` +
    `(reason: >=3 non-space chars, no '>', not a placeholder)`,
  review_tests:
    `workflow-mark: review_tests NOT recorded — MARK_STEP not accepted for this step. ` +
    `Invoke /review-tests skill (which auto-computes the review-scope fingerprint) ` +
    `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"`,
  docs:
    `workflow-mark: docs NOT recorded — MARK_STEP not accepted for this step. ` +
    `Run /update-docs, then satisfy either route: ` +
    `(a) stage docs/ or *.md files (git add docs/ ...); or ` +
    `(b) inside a linked worktree, ensure WORKTREE_NOTES.md ` +
    `## History Notes / ## Changelog Notes contain real bullets ` +
    `(not just "- (none)") — staging path introduced by #436 / #484. ` +
    `No MARK_STEP skip path.`,
});

function handle(ctx) {
  const { cmd, sessionId, pushMessage, pushUnapplied, repoCwd } = ctx;

  const markMatch = cmd.match(MARKER_RE_DQ) || cmd.match(MARKER_RE_SQ);

  // --- MARK_STEP handler ---
  if (markMatch) {
    const [, stepName, status] = markMatch;

    if (Object.prototype.hasOwnProperty.call(REFUSED_MARK_STEPS, stepName)) {
      pushUnapplied(REFUSED_MARK_STEPS[stepName]);
      return true;
    }

    // write_tests requires staged or committed test evidence (or NOT_NEEDED sentinel).
    // MARK_STEP is accepted only when evidence exists; otherwise reject with guidance.
    if (stepName === "write_tests") {
      if (!hasCompletionEvidence("write_tests", sessionId, { repoDir: repoCwd })) {
        pushUnapplied(
          `workflow-mark: write_tests NOT recorded — MARK_STEP not accepted for this step. ` +
            `Stage tests/ changes (run /write-tests then git add tests/) ` +
            `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"` +
            ` (reason must be >=3 non-space chars, no '>', not a placeholder)`
        );
        return true;
      }
      // Evidence present — fall through to the common markStep path below.
    }
    // run_tests may be skipped only on the docs-only route (mirrors the
    // write_tests evidence gate above): reject when the fact is false, fall
    // through to the common markStep path when it holds.
    if (stepName === "run_tests" && status === "skipped") {
      if (!isDocsOnlyStaged(repoCwd)) {
        pushUnapplied(
          `workflow-mark: run_tests NOT skipped — MARK_STEP skip is accepted only when ` +
            `every staged file is human-facing docs. Run the tests (/run-tests), ` +
            `or stage a docs-only set and emit: ` +
            `echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {reason}>>"`
        );
        return true;
      }
    }
    // Validate step name (regex already constrains status values)
    if (!VALID_STEPS.includes(stepName)) {
      pushUnapplied(`workflow-mark: unknown step "${stepName}" in marker — ignored.`);
      return true;
    }

    if (!sessionId) {
      pushUnapplied(
        `workflow-mark: could not resolve session_id — step "${stepName}" NOT recorded. ` +
          `Commit gate will block. Re-run: ` +
          `echo "<<WORKFLOW_MARK_STEP_${stepName}_${status}>>"`
      );
      return true;
    }

    // Deliberately NOT sanctioned: MARK_STEP_* is permissions.allow (freely
    // emittable by the model), so completing an approval-gated step must go
    // through the approval requirement, never around it (#1133).
    // The workflow_init downstream reset (#1068) is co-owned by the same writer.
    const res = recordStepVerdict(sessionId, stepName, status, {
      gate: "sentinel",
      provenance: "observed",
      origin: "mark-step",
      repoDir: repoCwd,
    });
    if (!res.ok && res.kind === "unapproved") {
      pushUnapplied(
        `workflow-mark: ${stepName} NOT recorded — no user approval on record ` +
          `(${res.detail}). MARK_STEP cannot approve a plan stage. ` +
          `Ask the user to approve, then emit: ` +
          `echo "<<${confirmSentinelFor(stepName)}: {summary}>>" ` +
          `(or verify CONFIRM_${stepName.toUpperCase()}=off in your config).`
      );
    } else if (!res.ok && RELAYED_KINDS.includes(res.kind)) {
      pushUnapplied(`workflow-mark: ${res.message.replace(/^record-step-verdict: /, "")}`);
    } else if (!res.ok) {
      pushUnapplied(
        `workflow-mark: failed to write state — ${res.detail || res.message}. Step "${stepName}" NOT recorded.`
      );
    } else if (res.kind === "downstream-reset-failed") {
      pushUnapplied(`workflow-mark: failed to reset downstream steps after workflow_init — ${res.detail}`);
    } else if (res.kind) {
      const notice = formatReviewTestsReopenNotice(res);
      if (notice) pushMessage(`workflow-mark: ${notice}`);
    }

    return true;
  }

  return false;
}

module.exports = { handle, REFUSED_MARK_STEPS };
