# shellcheck shell=bash
# Case bodies: WIP judgment is per commit. Set = {A}; only user_verification pending;
# A is a main checkout, so the linked-worktree exemption cannot hide the WIP judgment.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

WIP_ONE="git -C $A -c workflow.wip=1 commit -m x"

wip_state() { helper state "$1" user_verification "{\"cwd\":\"$A\"}"; }

tc_wip_later_element() {
  wip_state wr
  expect "(wip) runCommands [git -C A status, wip commit] -> approve" approve - \
    "$(gate wr "$A" "$A" runCommands "[\"git -C $A status\",\"$WIP_ONE\"]")"
}

tc_wip_later_line() {
  wip_state ws
  expect "(wip) Bash 'git -C A status<newline>wip commit' -> approve" approve - \
    "$(gate ws "$A" "$A" Bash "[\"git -C $A status\\n$WIP_ONE\"]")"
}

tc_wip_mixed() {
  wip_state wt
  expect "(wip) wip commit; non-wip commit -> block" block user_verification \
    "$(gate wt "$A" "$A" Bash "[\"git -C $A -c workflow.wip=1 commit -m a; git -C $A commit -m b\"]")"
}

tc_wip_single() {
  wip_state wu1
  expect "(wip) single wip commit -> approve" approve - \
    "$(gate wu1 "$A" "$A" Bash "[\"$WIP_ONE\"]")"
  wip_state wu2
  expect "(wip) single non-wip commit -> block" block user_verification \
    "$(gate wu2 "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
}
