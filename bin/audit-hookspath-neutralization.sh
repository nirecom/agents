#!/usr/bin/env bash
# bin/audit-hookspath-neutralization.sh — cross-repo core.hooksPath neutralization inventory
# Usage: bash bin/audit-hookspath-neutralization.sh --roots <dir> [<dir> ...]
# Report-only: never unsets. Flags repos whose repo-local core.hooksPath is neutralized.
set -euo pipefail

ROOTS=()
NEXT_IS_ROOT=0
for _arg in "$@"; do
    if [ "$_arg" = "--roots" ]; then
        NEXT_IS_ROOT=1
    elif [ "$NEXT_IS_ROOT" -eq 1 ]; then
        ROOTS+=("$_arg")
    else
        printf 'audit-hookspath-neutralization.sh: unknown argument: %s\n' "$_arg" >&2
        exit 1
    fi
done

if [ "${#ROOTS[@]}" -eq 0 ]; then
    printf 'Usage: audit-hookspath-neutralization.sh --roots <dir> [<dir> ...]\n' >&2
    exit 1
fi

# Normalize a path to a comparable form. Uses cygpath -m on Windows (Git Bash)
# to convert /tmp/... MSYS paths to C:/... form so both sides of the comparison
# use the same representation. Falls back to the original string elsewhere.
norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# Return 0 (neutralized) or 1 (clean) for a repo + hooksPath value.
is_neutralized() {
    local repo="$1" hpath="$2"
    [ -z "$hpath" ] && return 0
    [ "$(printf '%s' "$hpath" | tr '[:upper:]' '[:lower:]')" = "nul" ] && return 0
    [ "$hpath" = "/dev/null" ] && return 0
    local is_abs=0
    if [[ "$hpath" = /* ]] || [[ "$hpath" =~ ^[A-Za-z]: ]]; then
        is_abs=1
    fi
    if [ "$is_abs" -eq 1 ]; then
        local git_dir canonical_hooks nhpath ncanon
        git_dir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || return 1
        if [[ "$git_dir" = /* ]] || [[ "$git_dir" =~ ^[A-Za-z]: ]]; then
            canonical_hooks="$git_dir/hooks"
        else
            canonical_hooks="$repo/$git_dir/hooks"
        fi
        nhpath="$(norm_path "$hpath")"
        ncanon="$(norm_path "$canonical_hooks")"
        [ "$nhpath" = "$ncanon" ] && return 1
        return 0
    fi
    # Relative path: neutralized unless the resolved directory actually exists and
    # contains executable hooks (a non-existent or empty hooks dir disables dispatch).
    local resolved="$repo/$hpath"
    [ -d "$resolved" ] || return 0
    # If the directory exists but has no executable files it is still effectively empty.
    if ! ls -1 "$resolved" 2>/dev/null | grep -qv '^\.'; then
        return 0
    fi
    return 1
}

check_entry() {
    local entry="$1"
    [ -d "$entry" ] || return 0
    git -C "$entry" rev-parse --git-dir >/dev/null 2>&1 || return 0
    local hpath
    hpath="$(git -C "$entry" config --local --get core.hooksPath 2>/dev/null)" || return 0
    if is_neutralized "$entry" "$hpath"; then
        printf 'NEUTRALIZED: %s (hooksPath=%s)\n' "$entry" "$hpath"
    fi
}

for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || continue
    # Direct children
    for entry in "$root"/*/; do
        entry="${entry%/}"
        check_entry "$entry"
        # One level deeper to catch linked worktrees (e.g., git/worktrees/name/repo)
        for nested in "$entry"/*/; do
            nested="${nested%/}"
            check_entry "$nested"
        done
    done
done
