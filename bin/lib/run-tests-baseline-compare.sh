#!/usr/bin/env bash
# Failure-line comparison for bin/run-tests-baseline (#2956 S4/S8). Source-only, after
# run-tests-baseline-worktree.sh (rtb_wt_native) and run-tests-baseline-rename.sh (rtb_rename_pairs),
# with the test language registry loaded (tlr_stem) and ROOT set to the branch work tree.

RTB_CMP_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-tests-baseline-compare.js"
RTB_CMP_VERDICT="" RTB_CMP_NEW_COUNT=0 RTB_CMP_NEW_HEAD="[]" RTB_CMP_FP_BASE="" RTB_CMP_FP_BRANCH=""

# rtb_test_data_dir <rel> — the test's own data directory: its path minus its language's nameStrip.
rtb_test_data_dir() {
    local t="$1" s
    s="$(tlr_stem "${t##*/}")"
    case "$t" in
        */*) printf '%s' "${t%/*}/$s" ;;
        *) printf '%s' "$s" ;;
    esac
}

# rtb_test_changed <B2> <rel> [<old>] — rc 0 when the branch work tree changed the test file or
# its data dir against <B2> (committed, staged, unstaged or untracked; <old> and its data dir too,
# so a rename counts), 1 when it did not, 2 when git could not tell.
rtb_test_changed() {
    local b2="${1:?rtb_test_changed: B2 required}" rel="${2:?rtb_test_changed: rel required}" old="${3:-}" rc=0 untracked
    local -a spec=("$rel" "$(rtb_test_data_dir "$rel")/")
    if [[ -n "$old" ]]; then spec+=("$old" "$(rtb_test_data_dir "$old")/"); fi
    git --literal-pathspecs -C "$ROOT" diff --quiet "$b2" -- "${spec[@]}" 2>/dev/null || rc=$?
    case "$rc" in
        0) ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
    untracked="$(git --literal-pathspecs -C "$ROOT" ls-files --others --exclude-standard -- "${spec[@]}" 2>/dev/null)" || return 2
    [[ -n "$untracked" ]] && return 0
    return 1
}

# rtb_compare <B2> <base-wt> <base-res> <branch-res> <rel> <normal|interrupted> — compares the two
# result dirs' failure lines (the rename map is ROOT's renames since <B2>) and sets RTB_CMP_VERDICT
# (same|new|no-records|branch-missing|base-missing), RTB_CMP_NEW_COUNT, RTB_CMP_NEW_HEAD (JSON),
# RTB_CMP_FP_BASE and RTB_CMP_FP_BRANCH. rc 1 (and RTB_CMP_VERDICT="") when the comparer failed.
rtb_compare() {
    local b2="$1" wt="$2" base_res="$3" branch_res="$4" rel="$5" end="$6" map out tag
    RTB_CMP_VERDICT="" RTB_CMP_NEW_COUNT=0 RTB_CMP_NEW_HEAD="[]" RTB_CMP_FP_BASE="" RTB_CMP_FP_BRANCH=""
    map="$(mktemp)" || return 1
    rtb_rename_pairs "$ROOT" "$b2" . >"$map"
    local -a lines_out=()
    if [[ -n "${RTB_CMP_LINES_OUT:-}" ]]; then lines_out=(--new-lines-out "$(rtb_wt_native "$RTB_CMP_LINES_OUT")"); fi
    out="$(node "$(rtb_wt_native "$RTB_CMP_JS")" "${lines_out[@]}" --base-res "$(rtb_wt_native "$base_res")" \
        --branch-res "$(rtb_wt_native "$branch_res")" --file "$rel" --rename-map "$(rtb_wt_native "$map")" \
        --root "$(rtb_wt_native "$ROOT")" --base-wt "$(rtb_wt_native "$wt")" --branch-end "$end" 2>/dev/null)"
    rm -f "$map"
    out="$(printf '%s\n' "$out" | grep -m 1 $'^RESULT\t')" || return 1
    # shellcheck disable=SC2034  # read by the sourcing caller
    IFS=$'\t' read -r tag RTB_CMP_VERDICT RTB_CMP_NEW_COUNT RTB_CMP_NEW_HEAD RTB_CMP_FP_BASE RTB_CMP_FP_BRANCH <<<"$out"
    [[ "$tag" == RESULT && -n "$RTB_CMP_VERDICT" ]] || { RTB_CMP_VERDICT=""; return 1; }
    return 0
}
