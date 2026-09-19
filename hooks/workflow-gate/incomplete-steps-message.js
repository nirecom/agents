"use strict";
// hooks/workflow-gate/incomplete-steps-message.js
// Builds the "workflow steps not complete" block message for the commit gate.
// Presentation text only (asserted byte-identical by tests); returns the joined
// string and does NOT call block() — the caller in workflow-gate.js does.

/**
 * @param {string[]} incomplete - ordered list of incomplete step names.
 * @param {Object} incompleteReasons - per-step annotation reasons (review_tests).
 * @param {boolean} docsOnly - docs-only staged short-circuit flag.
 * @returns {string} the joined multi-line block message.
 */
function buildIncompleteStepsMessage(incomplete, incompleteReasons, docsOnly) {
  const SKILL_MAP = {
    workflow_init: '/workflow-init  OR for docs-only: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"',
    clarify_intent: '/clarify-intent  OR if intent is clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    outline: '/make-outline-plan  OR if unnecessary: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    detail:  '/make-detail-plan   OR if unnecessary: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    branching_complete: 'Read rules/branch.md + rules/worktree.md (on-demand-only), then: echo "<<WORKFLOW_BRANCHING_COMPLETE: main|branch: {name}|worktree: {path}>>"',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    review_tests: '/review-tests skill (emits <<WORKFLOW_REVIEW_TESTS_COMPLETE: token={hex}>> on adequate coverage; re-editing tests/ after a passing review invalidates the pairing — re-run /review-tests)',
    run_tests: 'invoke `run-tests` skill via the Skill tool (emits sentinel automatically); or run `bash tests/run-all.sh <files>` directly — the PostToolUse hook (workflow-run-tests.js) marks complete only from its RUN_CONTRACT line. Ad-hoc test commands (e.g. `pytest tests/`) no longer auto-complete: they demote run_tests to pending. When every staged file is human-facing documentation: echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {reason}>>" (rejected otherwise).',
    review_security: '/review-code-security  OR if unnecessary: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    docs: '/update-docs (then either: git add docs/*.md / *.md, OR — inside a linked worktree — let /update-docs stage bullets into WORKTREE_NOTES.md ## History Notes / ## Changelog Notes per #436)',
    user_verification: 'ENFORCE_WORKTREE=on + linked worktree → SKIP (deferred to /worktree-end Step 4; premature emit without an open PR is hard-blocked by workflow-gate — see issue #577) | ENFORCE_WORKTREE=off or main worktree → emit immediately: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder) — set Bash description to "User verification: approve if implementation is complete — approving unlocks the commit gate."  (ask dialog IS the confirmation — do NOT wait for a prior text reply, do NOT use MARK_STEP)',
  };

  const lines = [
    docsOnly && incomplete.length === 1 && incomplete[0] === "user_verification"
      ? "workflow-gate: docs-only commit — only user_verification is required."
      : `workflow-gate: the following workflow steps are not complete: ${incomplete.join(", ")}`,
    "",
    "To mark a step complete:",
  ];

  for (const step of incomplete) {
    if (SKILL_MAP[step]) {
      lines.push(`  ${step}: run ${SKILL_MAP[step]}`);
    } else {
      lines.push(
        `  ${step}: echo "<<WORKFLOW_MARK_STEP_${step}_complete>>"`
      );
    }
    if (step === "review_tests" && incompleteReasons[step] === "stale-token") {
      lines.push(
        "    (note: tests were re-edited after a passing review — staged-tests fingerprint changed; re-run /review-tests)"
      );
    }
    if (step === "review_tests" && incompleteReasons[step] === "stale-wsid") {
      lines.push(
        "    (note: stale-wsid — workflow session ID (wsid) changed since /review-tests was run; re-run /review-tests in the current session)"
      );
    }
    if (step === "review_tests" && incompleteReasons[step] === "warnings-pending") {
      lines.push(
        "    (note: /review-tests reported coverage warnings — re-run /write-tests to address gaps, then /review-tests again)"
      );
    }
  }

  return lines.join("\n");
}

module.exports = { buildIncompleteStepsMessage };
