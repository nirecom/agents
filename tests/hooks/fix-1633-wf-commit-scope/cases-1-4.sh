# shellcheck shell=bash
# Case bodies: the four scenarios of the commit-scope rule. A plays the agents repo,
# B another repo; detail is pending, so a checked commit blocks on the incomplete steps.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

# Case 1: the WF has not begun (no state file, or workflow_init pending) -> never checked.
tc_case1_no_state() {
  expect "(1) no state: commit to A -> approve" approve - \
    "$(gate c1none "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
  expect "(1) no state: commit to B -> approve" approve - \
    "$(gate c1none "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

tc_case1_init_pending() {
  helper state c1pend "workflow_init,detail" "{\"cwd\":\"$A\"}"
  expect "(1) workflow_init pending: commit to A -> approve" approve - \
    "$(gate c1pend "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
  expect "(1) workflow_init pending: commit to B -> approve" approve - \
    "$(gate c1pend "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

# Case 2: begun with session-start cwd A -> only A is in the WF target repo set.
tc_case2() {
  helper state c2 detail "{\"cwd\":\"$A\"}"
  expect "(2) cwd=A: commit to A -> block" block detail \
    "$(gate c2 "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
  expect "(2) cwd=A: commit to B -> approve" approve - \
    "$(gate c2 "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

# Case 3: begun with session-start cwd B -> the mirror image of Case 2.
tc_case3() {
  helper state c3 detail "{\"cwd\":\"$B\"}"
  expect "(3) cwd=B: commit to A -> approve" approve - \
    "$(gate c3 "$B" "$B" Bash "[\"git -C $A commit -m x\"]")"
  expect "(3) cwd=B: commit to B -> block" block detail \
    "$(gate c3 "$B" "$B" Bash "[\"git -C $B commit -m x\"]")"
}

# Case 4: cwd A plus a linked worktree of B in the intent -> A and all of B are in the set.
tc_case4() {
  helper state c4 detail "{\"cwd\":\"$A\"}"
  helper intent c4 "o/repo-b=$BL"
  expect "(4) intent BL: commit to A -> block" block detail \
    "$(gate c4 "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
  expect "(4) intent BL: commit to BL -> block" block detail \
    "$(gate c4 "$A" "$A" Bash "[\"git -C $BL commit -m x\"]")"
  expect "(4) intent BL: commit to B main checkout (same common dir) -> block" block detail \
    "$(gate c4 "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}
