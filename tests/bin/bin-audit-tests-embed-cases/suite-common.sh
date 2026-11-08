# Tests: bin/lib/test-embed-cases.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, fixture
# Sourced by every tests/bin/bin-audit-tests-embed-cases*.sh entrypoint right after its
# isolation pins — the completion ledger, check_eq and the suite-integrity check. The
# group is split over several entrypoints so run-all runs its parts in parallel.
# Holds no cases.

# Completion ledger: every case file's LAST line is `grp_done <its own basename>`.
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }

# check_eq <name> <want> <got> — named equality on top of the shared pass/fail.
check_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
  fi
}

# ec_sourced <entrypoint>... — the case files those entrypoints source, sorted.
ec_sourced() { sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "$@" | sort -u; }

# ec_suite_integrity <entrypoint> — GRP1: across all the group's entrypoints, every
# file of the folder is sourced and every sourced file exists; GRP2: every file this
# entrypoint sources ran through to its completion marker.
ec_suite_integrity() {
  local self="${1:?}" present all
  local -a entries=("${GROUP_DIR%/*}"/bin-audit-tests-embed-cases*.sh)
  present="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | sort)"
  all="$(ec_sourced "${entries[@]}")"
  check_eq "GRP1 every case file is sourced by an entrypoint and every sourced case file exists" "$present" "$all"
  check_eq "GRP2 every case file $(basename "$self") sources ran through to its completion marker" \
    "$(ec_sourced "$self")" "$(printf '%s' "$GRP_DONE" | sort)"
}

grp_done suite-common.sh
