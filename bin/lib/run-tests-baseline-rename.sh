#!/usr/bin/env bash
# Rename source for bin/run-tests-baseline (#2688). Source-only. A failing test the merge base
# does not have may be a renamed copy of a base test; git's rename detection names the old
# path, and the base runs that path instead (detail gains `-via-rename:<old>`).

RTB_RENAME_OUT=""

# rtb_rename_source_into <root> <base-sha> <rel> — RTB_RENAME_OUT = the old path that exists
# at <base-sha> and was renamed to <rel>, or "" when there is none (or more than one).
rtb_rename_source_into() {
    local root="$1" base="$2" rel="$3" status old new found=""
    RTB_RENAME_OUT=""
    while IFS=$'\t' read -r status old new; do
        [[ "$status" == R* && "$new" == "$rel" && -n "$old" ]] || continue
        git -C "$root" cat-file -e "$base:$old" 2>/dev/null || continue
        [[ -z "$found" ]] || return 0
        found="$old"
    done < <(git -C "$root" diff -M --name-status --diff-filter=R "$base" HEAD -- tests/ 2>/dev/null || true)
    # shellcheck disable=SC2034  # read by the sourcing caller
    RTB_RENAME_OUT="$found"
    return 0
}
