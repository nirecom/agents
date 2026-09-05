"use strict";
// SSOT for "where does this step's completion evidence live?".
//
// context-independent : the evidence is a PLANS_DIR artifact (intent/outline/
//   detail), so it survives a move to a different worktree unchanged.
// worktree-dependent  : the evidence is the working tree itself (a branch, a
//   test file, a commit), so it means nothing in another checkout.
//
// Inheritance granularity (#2218) reads this map; a wrong entry silently carries
// a worktree-bound completion into a worktree where that evidence never existed.

const CONTEXT_INDEPENDENT = "context-independent";
const WORKTREE_DEPENDENT = "worktree-dependent";

const CONTEXT_CLASS_VALUES = Object.freeze([CONTEXT_INDEPENDENT, WORKTREE_DEPENDENT]);

const STEP_CONTEXT_CLASS = Object.freeze({
  workflow_init: CONTEXT_INDEPENDENT,
  clarify_intent: CONTEXT_INDEPENDENT,
  research: CONTEXT_INDEPENDENT,
  outline: CONTEXT_INDEPENDENT,
  detail: CONTEXT_INDEPENDENT,
  branching_complete: WORKTREE_DEPENDENT,
  write_tests: WORKTREE_DEPENDENT,
  review_tests: WORKTREE_DEPENDENT,
  write_code: WORKTREE_DEPENDENT,
  run_tests: WORKTREE_DEPENDENT,
  review_security: WORKTREE_DEPENDENT,
  docs: WORKTREE_DEPENDENT,
  user_verification: WORKTREE_DEPENDENT,
  cleanup: WORKTREE_DEPENDENT,
  pre_final_report_gate: WORKTREE_DEPENDENT,
  final_report: WORKTREE_DEPENDENT,
});

// Total and never throwing: the inheritance loop consults it for every verdict,
// and an unknown step takes the conservative side (left pending, not inherited).
function isContextIndependentStep(step) {
  if (typeof step !== "string") return false;
  return Object.prototype.hasOwnProperty.call(STEP_CONTEXT_CLASS, step)
    && STEP_CONTEXT_CLASS[step] === CONTEXT_INDEPENDENT;
}

module.exports = {
  STEP_CONTEXT_CLASS,
  CONTEXT_CLASS_VALUES,
  isContextIndependentStep,
};
