#!/usr/bin/env bash
# Table 1 and the ledger stage of bin/run-tests-baseline (#2956 S6/S8). Source-only, after the
# ledger, compare, rename and worktree libs. Works on the caller's TESTS, CLS, DET, NEWC, NEWH,
# BR_RES, BR_END, RERUN, B2, ROOT, LOGDIR and TMP_BASE. The class/detail table is owned by
# docs/architecture/claude-code/test-result-contract.md.

# rtb_cls_branch_res <i> — the branch result dir of test <i> (an empty dir when there is none).
rtb_cls_branch_res() {
    local d="${BR_RES[$1]:-}"
    if [[ -z "$d" ]]; then
        d="$TMP_BASE/empty-$$.res"
        mkdir -p "$d" 2>/dev/null
    fi
    printf '%s' "$d"
}

# rtb_cls_new_lines <i> — announces $LOGDIR/<i>.new-lines.tsv, where the comparer wrote every new line.
rtb_cls_new_lines() {
    local i="$1" f="$LOGDIR/$1.new-lines.tsv"
    [[ "${NEWC[i]:-0}" -gt 0 ]] 2>/dev/null || return 0
    printf 'run-tests-baseline: new failure lines: %s %s (%s)\n' "${TESTS[$i]}" "$f" "${NEWC[i]}" >&2
}

# rtb_cls_table1 <i> <base-wt> <base-res> <old-or-empty> <base-detail> — classifies a base failure
# against the branch lines: CLS/DET/NEWC/NEWH. <base-detail> is the detail a `same` result keeps.
# shellcheck disable=SC2034  # CLS/DET/NEWC/NEWH are the caller's arrays
rtb_cls_table1() {
    local i="$1" wt="$2" base_res="$3" old="$4" d="$5" rel="${TESTS[$1]}" rc=0
    local -a old_arg=()
    [[ -z "$old" ]] || old_arg=("$old")
    NEWC[i]=0 NEWH[i]="[]"
    # A branch run that left no records (BR_NOREC) proves nothing either way (fail-closed).
    if [[ "${BR_NOREC[i]:-}" == 1 ]]; then
        CLS[i]="new-case-failure-on-branch"; DET[i]="case-records-missing-on-branch"; return 0
    fi
    mkdir -p "$LOGDIR" 2>/dev/null
    rm -f "$LOGDIR/$i.new-lines.tsv"
    if ! RTB_CMP_LINES_OUT="$LOGDIR/$i.new-lines.tsv" rtb_compare "$B2" "$wt" "$base_res" "$(rtb_cls_branch_res "$i")" "$rel" "${BR_END[i]:-normal}"; then
        CLS[i]="undetermined"; DET[i]="compare-failed"; return 0
    fi
    NEWC[i]="$RTB_CMP_NEW_COUNT" NEWH[i]="$RTB_CMP_NEW_HEAD"
    rtb_cls_new_lines "$i"
    # git unable to tell counts as changed (fail-closed: no proof from an unknown test file).
    rtb_test_changed "$B2" "$rel" "${old_arg[@]}" || rc=$?
    if [[ "$rc" -ne 1 ]]; then
        CLS[i]="file-verdict-preexisting"; DET[i]="test-file-changed"; return 0
    fi
    case "$RTB_CMP_VERDICT" in
        same) CLS[i]="preexisting"; DET[i]="$d" ;;
        no-records) CLS[i]="file-verdict-preexisting"; DET[i]="no-case-records" ;;
        branch-missing) CLS[i]="new-case-failure-on-branch"; DET[i]="case-records-missing-on-branch" ;;
        base-missing) CLS[i]="new-case-failure-on-branch"; DET[i]="case-records-missing-at-base" ;;
        new) CLS[i]="new-case-failure-on-branch"; DET[i]="$d-new-lines" ;;
        *) CLS[i]="undetermined"; DET[i]="compare-failed" ;;
    esac
    return 0
}

# rtb_cls_from_row <i> <fp> <base-detail> — table 1 against a ledger row file; 1 = no row file.
rtb_cls_from_row() {
    local i="$1" dir="$TMP_BASE/row-$$-$1.res"
    rtb_ledger_lines_load "$2" "$dir" "$TMP_BASE" || return 1
    rtb_cls_table1 "$i" "$ROOT" "$dir" "" "$3"
    rm -rf "$dir"
    return 0
}

# rtb_cls_base_fail <i> <run> <old-or-empty> — a failure the base run just showed: table 1, then the
# ledger row (keyed on the path the base ran) with the fp of its row file.
rtb_cls_base_fail() {
    local i="$1" run="$2" res="$LOGDIR/$RTB_EXEC_SEQ.res" fp
    rtb_cls_table1 "$i" "$WT" "$res" "$3" "fails-at-base-exit-$RTB_EXEC_RC"
    fp="$(rtb_ledger_lines_store "$res" "$ROOT" "$WT" "$TMP_BASE")"
    rtb_ledger_append "$B2" "$run" fail "$fp"
}

# rtb_cls_base_pass <i> <detail> — the base passes. A branch run that left no records (root decoy
# hit, unrunnable: BR_NOREC) has nothing to set the base against: records missing on the branch.
# shellcheck disable=SC2034
rtb_cls_base_pass() {
    if [[ "${BR_NOREC[$1]:-}" == 1 ]]; then
        CLS[$1]="new-case-failure-on-branch"; DET[$1]="case-records-missing-on-branch"
    else
        CLS[$1]="broken"; DET[$1]="$2"
    fi
}

# rtb_cls_inherit <i> — preexisting-inherited when an ancestor base's row file shows no new line
# and the test is unchanged; 1 when no candidate qualifies (the base runs).
# shellcheck disable=SC2034
rtb_cls_inherit() {
    local i="$1" t="${TESTS[$1]}" d b1 fp
    d="$(rtb_test_data_dir "$t")"
    while IFS=$'\t' read -r b1 fp; do
        [[ -n "$b1" && "$b1" != "$B2" ]] || continue
        ! rtb_ledger_lines_fresh "$fp" || continue
        git -C "$ROOT" cat-file -e "$b1^{commit}" 2>/dev/null || continue
        git -C "$ROOT" merge-base --is-ancestor "$b1" "$B2" 2>/dev/null || continue
        git --literal-pathspecs -C "$ROOT" diff --quiet "$b1" "$B2" -- "$t" "$d/" 2>/dev/null || continue
        rtb_cls_from_row "$i" "$fp" "inherited-from-$b1" || continue
        if [[ "${CLS[i]}" == "preexisting" ]]; then
            CLS[i]="preexisting-inherited"
            return 0
        fi
        # New lines against the older base: B2 may have fixed them, so B2 itself is run.
        unset 'CLS[i]' 'DET[i]'
        NEWC[i]=0 NEWH[i]="[]"
        return 1
    done < <(rtb_ledger_lookup_inheritable_fp "$t")
    return 1
}

# rtb_cls_ledger_stage — stage 4: (a) the same base, then (b) inheritance; the rest go to RERUN.
# A fail hit counts only with a readable, verified row file; otherwise the base re-runs.
# shellcheck disable=SC2034
rtb_cls_ledger_stage() {
    local i t same res fp
    for i in "${!TESTS[@]}"; do
        [[ -z "${CLS[i]:-}" ]] || continue
        t="${TESTS[$i]}"
        same="$(rtb_ledger_lookup_same_base "$B2" "$t")"
        res="${same%%$'\t'*}" fp="-"
        [[ "$same" != *$'\t'* ]] || fp="${same#*$'\t'}"
        case "$res" in
            fail)
                if [[ "$fp" != "-" ]] && ! rtb_ledger_lines_fresh "$fp" \
                    && rtb_cls_from_row "$i" "$fp" "ledger-same-base"; then continue; fi
                RERUN+=("$i"); continue ;;
            pass) rtb_cls_base_pass "$i" "ledger-same-base"; continue ;;
            und:*) CLS[i]="undetermined"; DET[i]="${res#und:}"; continue ;;
        esac
        rtb_cls_inherit "$i" || RERUN+=("$i")
    done
}
