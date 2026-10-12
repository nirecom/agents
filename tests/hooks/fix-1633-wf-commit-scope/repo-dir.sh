# shellcheck shell=bash
# Case bodies: where a bare `git commit` lands. resolveCommandIndependentRepo takes
# the payload cwd only when it is a linked worktree; a main checkout falls back to
# CLAUDE_PROJECT_DIR / process cwd / a staged guess, and only a project dir in the
# same repo as the payload cwd is deterministic. Anything else is ambiguous: checked.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

# Set = {A}, detail pending throughout.
rd_state() { helper state "$1" detail "{\"cwd\":\"$A\"}"; }

# Payload cwd BL is a linked worktree of B (outside the set) -> source payload-cwd -> out.
tc_rd_outside_linked_worktree() {
  rd_state rdl
  expect "(repo-dir) bare commit, payload cwd = linked worktree of B -> approve" approve - \
    "$(gate rdl "$BL" "$A" Bash '["git commit -m x"]')"
}

# Payload cwd B is a main checkout, so the resolver falls to project dir A, a different
# repo from the payload cwd: ambiguous, checked at A (known limitation of the plan).
tc_rd_outside_main_checkout() {
  rd_state rdm
  expect "(repo-dir) bare commit, payload cwd = B main checkout, project = A -> block" block detail \
    "$(gate rdm "$B" "$A" Bash '["git commit -m x"]')"
}

tc_rd_nondeterministic_source() {
  rd_state rdn
  expect "(repo-dir) bare commit, staged additionalDirectory guess -> block" block detail \
    "$(GATE_HOME="$ADD_HOME" gate rdn "$A" "$A" Bash '["git commit -m x"]')"
  expect "(repo-dir) bare commit, project unset, process cwd = B -> block" block detail \
    "$(GATE_CWD="$B" gate rdn "$B" - Bash '["git commit -m x"]')"
}

tc_rd_project_dir_mismatch() {
  rd_state rdp
  expect "(repo-dir) bare commit, payload cwd = A, project = B -> block" block detail \
    "$(gate rdp "$A" "$B" Bash '["git commit -m x"]')"
  expect "(repo-dir) contrast: payload cwd = B, project = B -> approve" approve - \
    "$(gate rdp "$B" "$B" Bash '["git commit -m x"]')"
}
