# shellcheck shell=bash
# Case bodies: one call that commits to several repos. T counts in-set repos by
# common dir, A counts ambiguous commits. H carries a staged >500-line code file,
# so Gate 2 shows which repo the gate checked.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

tc_mt_two_repos_split() {
  local out
  helper state mts - "{\"cwd\":\"$A\"}"
  helper intent mts "o/repo-b=$BL"
  out="$(gate mts "$A" "$A" Bash "[\"git -C $A commit -m a; git -C $BL commit -m b\"]")"
  expect "(multi) A and BL in one call (both in the set) -> block" block - "$out"
  expect_lacks "(multi) A+BL block is the split block, not incomplete steps" "not complete" "$out"
}

# Main checkout and linked worktree of one repo count as one repo: T = 1, not blocked.
tc_mt_main_and_linked_one_repo() {
  helper state mtl - "{\"cwd\":\"$A\"}"
  expect "(multi) A main checkout + AL in one call -> approve" approve - \
    "$(gate mtl "$A" "$A" Bash "[\"git -C $A commit -m a; git -C $AL commit -m b\"]")"
}

tc_mt_in_and_out_checks_in() {
  helper state mtg - "{\"cwd\":\"$G\"}"
  expect "(multi) set {G}: commit G and H (big staged in H) -> approve (checked at G)" approve - \
    "$(gate mtg "$G" "$G" Bash "[\"git -C $G commit -m a; git -C $H commit -m b\"]")"
  helper state mth - "{\"cwd\":\"$H\"}"
  expect "(multi) set {H}: commit G and H -> block on Gate 2 at H" block "500-line" \
    "$(gate mth "$H" "$H" Bash "[\"git -C $G commit -m a; git -C $H commit -m b\"]")"
}

tc_mt_ambiguous_with_two_members() {
  helper state mta2 - "{\"cwd\":\"$A\"}"
  helper intent mta2 "o/repo-b=$BL"
  expect "(multi) two-member set: commit A + xargs commit -> block (git -C guidance)" block "git -C" \
    "$(gate mta2 "$A" "$A" Bash "[\"git -C $A commit -m a; printf x | xargs git commit -m\"]")"
}

tc_mt_ambiguous_with_one_member() {
  helper state mta1 detail "{\"cwd\":\"$A\"}"
  expect "(multi) one-member set: commit A + xargs commit -> block on incomplete steps" block detail \
    "$(gate mta1 "$A" "$A" Bash "[\"git -C $A commit -m a; printf x | xargs git commit -m\"]")"
}

# Ambiguous-only: the explicit H commit is out, so the check target must not be H.
tc_mt_ambiguous_only_target() {
  local cmd="[\"git -C $H commit -m x; printf x | xargs git commit -m\"]"
  helper state mto - "{\"cwd\":\"$G\"}"
  expect "(multi) ambiguous-only, payload cwd GL (in) -> approve (checked at GL, not H)" approve - \
    "$(gate mto "$GL" "$G" Bash "$cmd")"
  expect "(multi) ambiguous-only, payload cwd HL (out) -> approve (checked at main repo G)" approve - \
    "$(gate mto "$HL" "$G" Bash "$cmd")"
}
