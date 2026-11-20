"use strict";
// The (class, detail) list decided outside decide, and the list decided on the reuse path (ledger, inheritance).
// shadow does not check live for these details (decide's input cannot determine them).

const U = ["undetermined"];
const entry = (id, detailPattern, classes, decidingInput) => Object.freeze({ id, detailPattern, classes, decidingInput });

const DETAILS_DECIDED_OUTSIDE_DECIDE = Object.freeze([
  entry("worktree-create-failed", /^worktree-create-failed$/, U, "whether the merge base side worktree could be created (bin/run-tests-baseline)"),
  entry("missing-at-base", /^missing-at-base$/, U, "whether the test file exists at the merge base (result of rtb_rename_resolve)"),
  entry("home-claude-ref", /^home-claude-ref$/, U, "whether the test file references $HOME/.claude (run-tests-baseline-homeref.sh)"),
  entry("budget-exhausted", /^budget-exhausted$/, U, "remaining budget of the whole run (run-tests-baseline-timeout.sh)"),
  entry("exceeds-budget", /^exceeds-budget$/, U, "whether the per-test cap exceeds the budget (run-tests-baseline-timeout.sh)"),
  entry("exec-setup-failed", /^exec-setup-failed$/, U, "whether the launcher setup succeeded (rtb_exec_one return value 2)"),
  entry("exit-<N>-then-pass", /^exit-([0-9]+|unknown)-then-pass$/, ["flaky-timeout-on-branch", "passes-alone-on-branch"],
    "exit code of the first failure on the branch side (a test that passed on rerun, rtb_branch_run_one)"),
  entry("base-launcher-predates-result-conversion", /^base-launcher-predates-result-conversion$/, U,
    "whether the merge base launcher predates test result conversion (wrapper language, no state)"),
  entry("state-<X>-at-base", /^state-.+-at-base$/, U, "unknown state string on the merge base side (decide's input has no state)"),
]);

const DETAILS_FROM_REUSE_PATH = Object.freeze([
  entry("ledger-same-base", /^ledger-same-base(-new-lines)?$/, ["broken", "preexisting", "new-case-failure-on-branch"],
    "ledger row already recorded for the same merge base (run-tests-baseline-ledger.sh)"),
  entry("inherited-from-*", /^inherited-from-[0-9a-f]+$/, ["preexisting-inherited"], "classification inherited from an earlier run (state of an ancestor commit)"),
  entry("preexisting-inherited", /^preexisting-inherited$/, ["preexisting-inherited"], "classification inherited from an earlier run"),
]);

module.exports = { DETAILS_DECIDED_OUTSIDE_DECIDE, DETAILS_FROM_REUSE_PATH };
