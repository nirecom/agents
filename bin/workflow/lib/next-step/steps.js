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
  review_docs: "review-docs",
  push_branch: "commit-push",
  user_verification: "get-release-approval",
  deliver: "deliver",
  cleanup: "worktree-end",
  pre_final_report_gate: "session-close",
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
  review_docs: "Review doc line limits and README section order",
  push_branch: "Model commits, pushes the branch, and opens the PR",
  user_verification: "Model runs /get-release-approval to obtain the user release approval",
  deliver: "Model performs the delivery operation (PR merge or direct push)",
  cleanup: "Model removes the worktree and the merged branch",
  pre_final_report_gate: "Final report and session close",
  final_report: "Final report delivered (terminal)",
});

const STEP_HINT = Object.freeze({
  branching_complete: "Emit WORKFLOW_BRANCHING_COMPLETE sentinel. Run /worktree-start first if needed, then enter the worktree (EnterWorktree tool, or cd) before any Edit/Write — see skills/_shared/worktree-transition.md.",
});
// Skill-backed steps carry no STEP_HINT: verdict.js builds their hint from STEP_TO_SKILL.

// #2327: NEXT_HINT when review_tests was reopened by a write_code completion.
const REVIEW_TESTS_REOPEN_HINT = "Run /review-tests via the Skill tool: write_code changed the review scope after the first review. When it completes, run next-step again and follow its ACTION; do not re-run /write-code.";

// Which steps a session owes is the step table (hooks/workflow-state/step-table.js);
// effectiveStatus applies its table-skip in hooks/workflow-state/effective-state.js.

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
  checkNoQuote({ REVIEW_TESTS_REOPEN_HINT }, "REVIEW_TESTS_REOPEN_HINT");
})();

module.exports = { STEP_TO_SKILL, STEP_DESC, STEP_HINT, REVIEW_TESTS_REOPEN_HINT, isTerminalStep };
