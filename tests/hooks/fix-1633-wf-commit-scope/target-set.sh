# shellcheck shell=bash
# Case bodies: the window where an intent sibling's worktree_path does not exist yet.
# Membership of any other repo is then unknowable: an explicit commit is checked at
# its own dir (possibly-in); an unresolvable commit target blocks with -C guidance.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

# ts_state <sid> <pending-csv|-> — cwd A plus one intent sibling that is not created yet.
ts_state() {
  helper state "$1" "$2" "{\"cwd\":\"$A\"}"
  helper intent "$1" "o/later=$MISSING"
}

tc_ts_other_repo_checked() {
  local out
  ts_state tsc detail
  out="$(gate tsc "$A" "$A" Bash "[\"git -C $C commit -m x\"]")"
  expect "(target-set) unresolved sibling: commit to C -> block on incomplete steps" block detail "$out"
  expect_lacks "(target-set) commit to C: no git -C split guidance" "git -C" "$out"
}

tc_ts_main_checked() {
  ts_state tsa detail
  expect "(target-set) unresolved sibling: commit to A -> block" block detail \
    "$(gate tsa "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
}

# All steps complete: a block can only come from the T >= 2 split rule.
tc_ts_main_and_other_split() {
  local out
  ts_state tsac -
  out="$(gate tsac "$A" "$A" Bash "[\"git -C $A commit -m a; git -C $C commit -m b\"]")"
  expect "(target-set) commit to A and C in one call -> block (two repos)" block - "$out"
  expect_lacks "(target-set) A+C block is not the incomplete-steps block" "not complete" "$out"
}

tc_ts_ambiguous_two_members() {
  ts_state tsx -
  expect "(target-set) xargs git commit with a two-member set -> block (git -C guidance)" block "git -C" \
    "$(gate tsx "$A" "$A" Bash "[\"printf x | xargs git commit -m\"]")"
}
