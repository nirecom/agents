# shellcheck shell=bash
# Case bodies: how the begun verdict feeds the gate. An unreadable state stays
# fail-closed with a reason-specific message; a state that cannot name its target
# set is checked; a RESET back to workflow_init returns the session to not-begun.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

tc_begun_corrupt() {
  corrupt bcorrupt
  expect "(begun) corrupt state: commit to B -> block (unreadable)" block unreadable \
    "$(gate bcorrupt "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

tc_begun_traversal() {
  expect "(begun) traversal session id: commit to B -> block (not a valid session id)" block \
    "not a valid session id" "$(gate "../../etc/passwd" "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

tc_begun_init_in_progress() {
  helper state binprog detail "{\"cwd\":\"$A\",\"__steps\":{\"workflow_init\":\"in_progress\"}}"
  expect "(begun) workflow_init in_progress: commit to A -> block" block detail \
    "$(gate binprog "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
}

# No session-start cwd: the target set is unknown, so every resolvable commit is checked.
tc_begun_no_cwd() {
  helper state bnocwd detail
  expect "(begun) no cwd, detail pending: commit to B -> block" block detail \
    "$(gate bnocwd "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
  helper state bnocwdok -
  expect "(begun) no cwd, all steps complete: commit to B -> approve" approve - \
    "$(gate bnocwdok "$A" "$A" Bash "[\"git -C $B commit -m x\"]")"
}

# RESET_FROM_workflow_init puts workflow_init back to pending: the session is not begun
# again until wf-init runs, so commits approve (an accepted tradeoff of the plan).
tc_begun_reset_to_init() {
  local st
  helper state breset detail "{\"cwd\":\"$A\"}"
  expect "(begun) before RESET: commit to A -> block" block detail \
    "$(gate breset "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
  reset_from breset workflow_init
  st="$(helper status breset workflow_init)"
  if [ "$st" = "pending" ]; then pass "(begun) RESET put workflow_init back to pending"
  else fail "(begun) RESET put workflow_init back to pending" "workflow_init status: $st"; fi
  expect "(begun) after RESET_FROM_workflow_init: commit to A -> approve" approve - \
    "$(gate breset "$A" "$A" Bash "[\"git -C $A commit -m x\"]")"
}
