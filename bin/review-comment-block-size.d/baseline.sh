#!/bin/bash
#
# bin/review-comment-block-size.d/baseline.sh
#
# Sourced by bin/review-comment-block-size. Answers "what does this staged path
# look like before the change?" — HEAD first, then the refs of an in-progress
# merge / cherry-pick / revert / rebase.
#
# Must be `source`d, not executed directly — it reads $HEAD_OK, publishes
# BASE_SPEC / BASE_REFS, and sets the caller's $LABEL.

# --- baseline resolution ---------------------------------------------------
BASE_SPEC=""
BASE_REFS=()
HEAD_OK=0

# A tree lookup, not an object lookup: a listed path whose blob is missing must
# stay "exists but unreadable" (an error), never "no baseline" (a fallback).
tree_has() {
    local out
    out="$(git ls-tree --name-only "$1" -- ":(literal)$2" 2>/dev/null || true)"
    [[ -n "$out" ]]
}

find_baseline() {
    local src="$1" r
    BASE_SPEC=""
    if [[ "$HEAD_OK" -eq 1 ]] && tree_has HEAD "$src"; then
        BASE_SPEC="HEAD:./$src"
        return 0
    fi
    for r in ${BASE_REFS[@]+"${BASE_REFS[@]}"}; do
        if tree_has "$r" "$src"; then
            BASE_SPEC="$r:./$src"
            return 0
        fi
    done
    return 1
}

collect_inprogress_refs() {
    local gitdir pair name sha i=0 line
    gitdir="$(git rev-parse --git-dir 2>/dev/null || true)"
    [[ -n "$gitdir" ]] || return 0
    if [[ -f "$gitdir/MERGE_HEAD" ]]; then
        LABEL="merge"
        while IFS= read -r line || [[ -n "${line:-}" ]]; do
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            [[ "$i" -ge 8 ]] && break
            git rev-parse --verify --quiet "${line}^{commit}" >/dev/null 2>&1 || continue
            BASE_REFS+=("$line")
            i=$((i + 1))
        done < "$gitdir/MERGE_HEAD"
    fi
    for pair in "CHERRY_PICK_HEAD:cherry-pick" "REVERT_HEAD:revert" "REBASE_HEAD:rebase"; do
        name="${pair%%:*}"
        [[ -f "$gitdir/$name" ]] || continue
        [[ -z "$LABEL" ]] && LABEL="${pair##*:}"
        sha="$(head -n 1 "$gitdir/$name" 2>/dev/null | tr -d '\r\n' || true)"
        [[ -n "$sha" ]] || continue
        git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1 || continue
        BASE_REFS+=("$sha")
    done
    return 0
}
