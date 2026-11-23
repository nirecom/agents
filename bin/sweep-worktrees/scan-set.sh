#!/bin/bash
#
# bin/sweep-worktrees/scan-set.sh — sourced by bin/sweep-worktrees.sh (#1610). Builds the set of
# worktree bases to scan: the CWD repo plus every --repo, each resolved by bin/worktree-base (the
# single resolver). Repos sharing a base (an explicit WORKTREE_BASE_DIR) are grouped so that base
# is scanned once. Fills SCAN_BASES (base_norm -> base) and SCAN_BASE_OWNERS (base_norm -> main
# roots, newline-separated). A --repo that is not a git main worktree is skipped with a WARN.

_SCAN_SET_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

declare -A SCAN_BASES=()
declare -A SCAN_BASE_OWNERS=()
declare -A _SCAN_SEEN_ROOTS=()

# scan_set_add <dir> <fatal:0|1> — resolve <dir> to (main root, base) and record it.
scan_set_add() {
  local dir="$1" fatal="$2" root out base base_norm root_norm
  root="$(main_worktree_of "$dir")" || root=""
  if [[ -z "$root" ]]; then
    [[ "$fatal" == "1" ]] && return 1
    printf 'WARN: --repo %s is not a git main worktree; skipping\n' "$dir" >&2
    return 0
  fi
  root_norm="$(norm_path "$root")"
  [[ -n "${_SCAN_SEEN_ROOTS[$root_norm]+x}" ]] && return 0
  if ! out="$(bash "$_SCAN_SET_CHECKOUT_ROOT/bin/worktree-base" --repo "$root" 2>&1)"; then
    printf 'WARN: cannot resolve the worktree base of %s: %s\n' "$root" "$out" >&2
    [[ "$fatal" == "1" ]] && return 1
    return 0
  fi
  base="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_BASE=//p' | tr -d '\r')"
  [[ -n "$base" ]] || return 1
  _SCAN_SEEN_ROOTS["$root_norm"]=1
  base_norm="$(norm_path "$base")"
  # shellcheck disable=SC2034  # read by the sourcing bin/sweep-worktrees.sh
  SCAN_BASES["$base_norm"]="$base"
  SCAN_BASE_OWNERS["$base_norm"]+="$root"$'\n'
}

# scan_set_build <cwd main root> [--repo dir]... — the CWD repo must resolve; each --repo may not.
scan_set_build() {
  local first="$1" extra
  shift
  if ! scan_set_add "$first" 1; then
    printf 'ERROR: cannot resolve the worktree base of %s\n' "$first" >&2
    return 1
  fi
  for extra in "$@"; do
    scan_set_add "$extra" 0
  done
}

# scan_set_owners <base_norm> — print the owner main roots of a base, one per line.
scan_set_owners() {
  printf '%s' "${SCAN_BASE_OWNERS[$1]:-}" | sed '/^$/d'
}
