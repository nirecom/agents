"use strict";
// Step lookup tables for bin/workflow/next-step, plus the import-time invariant
// assertions. Requiring this module (directly or transitively) is what makes the
// assertions run — every subcommand path must reach it.

const { VALID_STEPS, TERMINAL_STEPS } = require("../../../../hooks/workflow-state");

// ---- Lookup tables --------------------------------------------------------

const STEP_TO_SKILL = Object.freeze({
  workflow_init: "workflow-init",
  clarify_intent: "clarify-intent",
  research: "survey-code",
  outline: "make-outline-plan",
  detail: "make-detail-plan",
  branching_complete: "",
  write_tests: "write-tests",
  review_tests: "review-tests",
  write_code: "write-code",
  run_tests: "run-tests",
  review_security: "review-code-security",
  docs: "update-docs",
  user_verification: "",
  cleanup: "",
  pre_final_report_gate: "",
  // Terminal step: recorded, never advised. See isTerminalStep below.
  final_report: "",
});

const STEP_DESC = Object.freeze({
  workflow_init: "Initialize session state and GitHub issue",
  clarify_intent: "Interview and write intent.md",
  research: "Run survey-code and/or deep-research",
  outline: "Propose high-level approaches",
  detail: "File-level implementation plan",
  branching_complete: "Create feature branch and worktree",
  write_tests: "Write tests for planned changes",
  review_tests: "Review test coverage adequacy",
  write_code: "Implement the planned changes",
  run_tests: "Run test suite and security review",
  review_security: "Adversarial security review and code quality gates",
  docs: "Update docs and changelog",
  user_verification: "User verifies the implementation",
  cleanup: "Remove worktree and merge branch",
  pre_final_report_gate: "Final report and session close",
  final_report: "Final report delivered (terminal)",
});

const STEP_HINT = Object.freeze({
  branching_complete: "Emit WORKFLOW_BRANCHING_COMPLETE sentinel. Run /worktree-start first if needed, then enter the worktree (EnterWorktree tool, or cd) before any Edit/Write — see skills/_shared/worktree-transition.md.",
  user_verification: "ENFORCE_WORKTREE=on: do NOT emit here — defer to /worktree-end WE-8. ENFORCE_WORKTREE=off: emit just before /commit-push. See skills/_shared/user-verified.md for preflight and protocol. If you have already emitted the sentinel and then ran gh pr merge, the step is already complete — do not emit again.",
  cleanup: "Run /worktree-end (worktree path), delete branch + git push origin --delete (branch path), or echo WORKFLOW_MARK_STEP_cleanup_skipped (main/no-worktree path).",
  pre_final_report_gate: "Run /session-close from the main worktree.",
});

// WF_META_AUTO_SKIP / effectiveStatus now live in
// hooks/workflow-state/effective-state.js (SSOT).

// A terminal step (SSOT: state-io TERMINAL_STEPS) is a boundary marker in the
// event stream, not work to be advised: nothing comes after it, and no skill
// completes it. It is therefore excluded from every walk that answers "what is
// the current step?" — otherwise a finished session would be told forever to run
// a skill that does not exist.
const TERMINAL_STEP_SET = new Set(Array.isArray(TERMINAL_STEPS) ? TERMINAL_STEPS : []);
function isTerminalStep(step) {
  return TERMINAL_STEP_SET.has(step);
}

// ---- Import-time assertions -----------------------------------------------

(function assertInvariants() {
  for (const step of VALID_STEPS) {
    if (!Object.prototype.hasOwnProperty.call(STEP_TO_SKILL, step)) {
      console.error("next-step: missing STEP_TO_SKILL entry for " + step);
      process.exit(1);
    }
    if (!Object.prototype.hasOwnProperty.call(STEP_DESC, step)) {
      console.error("next-step: missing STEP_DESC entry for " + step);
      process.exit(1);
    }
  }
  const checkNoQuote = (obj, label) => {
    for (const k of Object.keys(obj)) {
      if (typeof obj[k] === "string" && obj[k].indexOf("'") !== -1) {
        console.error("next-step: single-quote character in " + label + "[" + k + "]");
        process.exit(1);
      }
    }
  };
  checkNoQuote(STEP_TO_SKILL, "STEP_TO_SKILL");
  checkNoQuote(STEP_DESC, "STEP_DESC");
  checkNoQuote(STEP_HINT, "STEP_HINT");
})();

module.exports = { STEP_TO_SKILL, STEP_DESC, STEP_HINT, isTerminalStep };
