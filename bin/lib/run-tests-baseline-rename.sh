#!/usr/bin/env bash
# Rename source for bin/run-tests-baseline (#2688). Source-only. A failing test the merge base
# does not have may be a renamed copy of a base test; git's rename detection names the old
# path, and the base runs that path instead (detail gains `-via-rename:<old>`).

RTB_RENAME_OUT=""

# rtb_rename_pairs <root> <base-sha> <pathspec> — prints `<old>\t<new>` for each rename under
# <pathspec> whose old path exists at <base-sha>. Committed (base..HEAD) and staged (base..index)
# renames are both consulted (#2951); the same pair seen by both is one, and a new path with more
# than one distinct old path is ambiguous and dropped. The #2956 comparer reads it as its rename map.
rtb_rename_pairs() {
    local root="$1" base="$2" spec="$3" status old new
    {
        git -C "$root" diff -M --name-status --diff-filter=R "$base" HEAD -- "$spec" 2>/dev/null || true
        git -C "$root" diff -M --cached --name-status --diff-filter=R "$base" -- "$spec" 2>/dev/null || true
    } | while IFS=$'\t' read -r status old new; do
        [[ "$status" == R* && -n "$old" && -n "$new" ]] || continue
        git -C "$root" cat-file -e "$base:$old" 2>/dev/null || continue
        printf '%s\t%s\n' "$old" "$new"
    done | LC_ALL=C sort -u | awk -F'\t' '{ n[$2]++; o[$2] = $1; k[NR] = $2 }
        END { for (i = 1; i <= NR; i++) if (n[k[i]] == 1) print o[k[i]] "\t" k[i] }'
}

# rtb_rename_source_into <root> <base-sha> <rel> — RTB_RENAME_OUT = the old path that exists
# at <base-sha> and was renamed to <rel> under tests/, or "" when there is none (or it is ambiguous).
rtb_rename_source_into() {
    local root="$1" base="$2" rel="$3" old new found=""
    while IFS=$'\t' read -r old new; do
        if [[ "$new" == "$rel" ]]; then found="$old"; fi
    done < <(rtb_rename_pairs "$root" "$base" tests/)
    # shellcheck disable=SC2034  # read by the sourcing caller
    RTB_RENAME_OUT="$found"
    return 0
}
