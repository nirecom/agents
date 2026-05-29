#!/usr/bin/env bash
# Tests for issue-close-finalize SKILL.md invariants:
#   - #612 (PR3): SKILL.md shortening + lib/ -> scripts/ migration
#   - #636: tmpfile/mktemp pattern blocked from main worktree under
#     ENFORCE_WORKTREE=on; SKILL.md must use `eval "$(bash ...)"` instead.
set -euo pipefail

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

cd "$(git rev-parse --show-toplevel)"

PASS=0
FAIL=0
FAILED_TESTS=()

assert() {
    local name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        echo "FAIL: $name"
    fi
}

# ---------------- Group 1: tmpfile/mktemp absence (main-worktree compat, #636) ----------------
# issue-close-finalize runs from the main worktree under ENFORCE_WORKTREE=on,
# where mktemp + `> redirect` are blocked writes. SKILL.md must use the
# `eval "$(bash ...)"` pattern instead of tmpfile+dot-source.

test_t1_no_tmpfile_in_skill_md() {
    local FAILED=0
    if grep -qE 'tmpfile|mktemp' skills/issue-close-finalize/SKILL.md; then
        echo "  tmpfile/mktemp pattern found in SKILL.md (blocked from main worktree, see #636)"
        FAILED=1
    fi
    return $FAILED
}

test_t3_skill_md_line_count() {
    local lines
    lines=$(wc -l < skills/issue-close-finalize/SKILL.md)
    if [ "$lines" -le 130 ]; then
        return 0
    fi
    echo "  SKILL.md is $lines lines (>130)"
    return 1
}

# ---------------- Group 2: scripts/ structure ----------------

test_t4_pre_flight_exists_executable() {
    local f="skills/issue-close-finalize/scripts/pre-flight.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

test_t5_step_e_exists_executable() {
    local f="skills/issue-close-finalize/scripts/step-e.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

test_t6_step_g5_loop_exists_executable() {
    local f="skills/issue-close-finalize/scripts/step-g5-loop.sh"
    [ -f "$f" ] && [ -x "$f" ]
}

# ---------------- Group 3: ST1/ST2/ST3 ordering invariants ----------------

test_t7_st1_triage_before_pr_marker() {
    local skill="skills/issue-close-finalize/SKILL.md"
    local triage_line marker_line
    triage_line=$(grep -nF 'triage.sh' "$skill" | head -1 | cut -d: -f1)
    marker_line=$(grep -nF 'find-pr-by-marker.sh' "$skill" | head -1 | cut -d: -f1)
    if [ -z "$triage_line" ] || [ -z "$marker_line" ]; then
        echo "  triage.sh line: '$triage_line', find-pr-by-marker.sh line: '$marker_line'"
        return 1
    fi
    [ "$triage_line" -lt "$marker_line" ]
}

test_t8_st2_jpath_near_pr_marker() {
    local skill="skills/issue-close-finalize/SKILL.md"
    local marker_line jpath_line diff
    marker_line=$(grep -nF 'find-pr-by-marker.sh' "$skill" | head -1 | cut -d: -f1)
    if [ -z "$marker_line" ]; then
        return 1
    fi
    # Find any line containing the literal *,J,*
    while IFS=: read -r ln _; do
        diff=$((ln - marker_line))
        if [ "$diff" -lt 0 ]; then diff=$((-diff)); fi
        if [ "$diff" -le 25 ]; then
            return 0
        fi
    done < <(grep -nF '*,J,*' "$skill")
    echo "  *,J,* not within 25 lines of find-pr-by-marker.sh (line $marker_line)"
    return 1
}

test_t9_st3_ordering_contract_comment() {
    grep -qF 'ordering-contract: PR/SHA resolution MUST run after triage' \
        skills/issue-close-finalize/SKILL.md
}

# ---------------- Group 4: lib/ -> scripts/+reference/ migration ----------------

test_m1_worktree_end_lib_removed() {
    [ ! -d skills/worktree-end/lib ]
}

test_m2_worktree_end_scripts_present() {
    local FAILED=0
    for f in capture-env.sh detect-restart.sh extract-pr-fields.js read-notes-path.js write-env-json.js; do
        if [ ! -f "skills/worktree-end/scripts/$f" ]; then
            echo "  missing: skills/worktree-end/scripts/$f"
            FAILED=1
        fi
    done
    return $FAILED
}

test_m3_clarify_intent_lib_removed() {
    [ ! -d skills/clarify-intent/lib ]
}

test_m4_clarify_intent_reference_present() {
    local FAILED=0
    for f in aggregate-class-members.md class-members-proposal.md; do
        if [ ! -f "skills/clarify-intent/reference/$f" ]; then
            echo "  missing: skills/clarify-intent/reference/$f"
            FAILED=1
        fi
    done
    return $FAILED
}

test_m5_no_lingering_lib_references() {
    local matches
    matches=$(grep -rl 'skills/worktree-end/lib\|skills/clarify-intent/lib' skills/ 2>/dev/null \
        | grep -v 'history' \
        | grep -v 'feature-issue-close-finalize-no-tmpfile' \
        || true)
    if [ -z "$matches" ]; then
        return 0
    fi
    echo "  lingering references found in:"
    echo "$matches" | sed 's/^/    /'
    return 1
}

# ---------------- Runner ----------------

run() {
    local name="$1"
    local fn="$2"
    local rc=0
    "$fn" || rc=$?
    assert "$name" "$rc"
}

run "T1: no tmpfile/mktemp in SKILL.md (#636)"      test_t1_no_tmpfile_in_skill_md
run "T3: SKILL.md <= 130 lines"                     test_t3_skill_md_line_count
run "T4: scripts/pre-flight.sh exists+exec"         test_t4_pre_flight_exists_executable
run "T5: scripts/step-e.sh exists+exec"             test_t5_step_e_exists_executable
run "T6: scripts/step-g5-loop.sh exists+exec"       test_t6_step_g5_loop_exists_executable
run "T7 (ST1): triage.sh before find-pr-by-marker"  test_t7_st1_triage_before_pr_marker
run "T8 (ST2): *,J,* within 25 lines of marker"     test_t8_st2_jpath_near_pr_marker
run "T9 (ST3): ordering-contract comment present"   test_t9_st3_ordering_contract_comment
run "M1: worktree-end/lib/ removed"                 test_m1_worktree_end_lib_removed
run "M2: worktree-end/scripts/ files present"       test_m2_worktree_end_scripts_present
run "M3: clarify-intent/lib/ removed"               test_m3_clarify_intent_lib_removed
run "M4: clarify-intent/reference/ files present"   test_m4_clarify_intent_reference_present
run "M5: no lingering lib/ references"              test_m5_no_lingering_lib_references

echo ""
echo "==== Summary ===="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
exit 0
