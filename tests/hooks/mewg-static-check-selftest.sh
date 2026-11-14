#!/bin/bash
# tests/hooks/mewg-static-check-selftest.sh
# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, scope:common, enforce-worktree, tests, test-lang-exception:e2e
# Self-test of mewg_static_check (tests/lib/mewg-groups.sh): each way the fragment table, the fragment
# directory and the main-enforce-worktree-guard-<group>.sh entrypoints can disagree must FAIL,
# and the agreeing tree must stay silent. Runs on a synthetic temp tree; the real tree is never changed.
# Deliberately not named main-enforce-worktree-guard-*.sh: that name is an entrypoint to the static check.
# TL3 gap: the check is exercised on a synthetic tree, so a real entrypoint the table forgot is caught
# only by the entrypoints' own static check run, not here.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REAL_ROOT="$SCRIPT_CHECKOUT_ROOT"

# Shared harness first (root decoy, run root, command guard); mewg-harness.sh below redefines pass/fail/skip.
# shellcheck source=tests/lib/harness.sh
. "$REAL_ROOT/tests/lib/harness.sh"

ST_TMP_ROOT="$(mktemp -d)"
readonly ST_TMP_ROOT
TMPDIR_BASE="$ST_TMP_ROOT"
trap 'rm -rf "$ST_TMP_ROOT"' EXIT

# rules/test/fixture-isolation.md: pin the workflow dir and the plans dir as a PAIR.
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/workflow-plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID

# shellcheck source=tests/lib/mewg-harness.sh
. "$REAL_ROOT/tests/lib/mewg-harness.sh"
# shellcheck source=tests/lib/mewg-groups.sh
. "$REAL_ROOT/tests/lib/mewg-groups.sh"

# build_tree <dir>: a tree that agrees with MEWG_TABLE.
build_tree() {
    local dir="$1" entry g
    mkdir -p "$dir/tests/hooks/main-enforce-worktree-guard"
    for entry in "${MEWG_TABLE[@]}"; do : > "$dir/tests/hooks/main-enforce-worktree-guard/${entry%%:*}"; done
    for g in $(mewg_groups); do
        printf 'MEWG_GROUP="%s"\n' "$g" > "$dir/tests/hooks/main-enforce-worktree-guard-$g.sh"
    done
}

# run_check <dir> <group> [eval-string]: the static check in a subshell against <dir>; sets OUT and RC.
# The subshell's own FAIL lines are captured into OUT, never printed as this test's result lines.
run_check() {
    local dir="$1" group="$2" extra="${3:-}"
    OUT="$(
        # Points the library at the synthetic tree for this subshell only (the real root is assigned once, above).
        printf -v SCRIPT_CHECKOUT_ROOT '%s' "$dir"
        FRAGMENT_DIR="$dir/tests/hooks/main-enforce-worktree-guard"
        eval "$extra"
        mewg_static_check "$group"
    )"
    RC=$?
}

# expect_fail <name> <dir> <group> <expected substring> [eval-string]
expect_fail() {
    run_check "$2" "$3" "${5:-}"
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF -- "$4"; then
        pass "$1"
    else
        fail "$1 (rc=$RC out=[$OUT])"
    fi
}

t="$ST_TMP_ROOT/clean"
build_tree "$t"
run_check "$t" "mixed-a"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "S1 agreeing tree is silent"; else fail "S1 agreeing tree is silent (rc=$RC out=[$OUT])"; fi

t="$ST_TMP_ROOT/unassigned"
build_tree "$t"
: > "$t/tests/hooks/main-enforce-worktree-guard/stray.sh"
expect_fail "S2 fragment present but not in the table" "$t" "mixed-a" "FRAG1 fragment set mismatch"

t="$ST_TMP_ROOT/absent"
build_tree "$t"
rm -f "$t/tests/hooks/main-enforce-worktree-guard/merge-gate.sh"
expect_fail "S3 table fragment missing from the directory" "$t" "mixed-a" "FRAG1 fragment set mismatch"

t="$ST_TMP_ROOT/dup"
build_tree "$t"
expect_fail "S4 fragment assigned to two groups" "$t" "mixed-a" "FRAG3 fragment assigned to more than one group" 'MEWG_TABLE+=("merge-gate.sh:mixed-a")'

t="$ST_TMP_ROOT/no-entry"
build_tree "$t"
rm -f "$t/tests/hooks/main-enforce-worktree-guard-push-range.sh"
expect_fail "S5 group without an entrypoint" "$t" "mixed-a" "group-without-entrypoint: [push-range]"

t="$ST_TMP_ROOT/no-group"
build_tree "$t"
printf 'MEWG_GROUP="extra"\n' > "$t/tests/hooks/main-enforce-worktree-guard-extra.sh"
expect_fail "S6 entrypoint without a group" "$t" "mixed-a" "entrypoint-without-group: [extra]"

t="$ST_TMP_ROOT/mislabeled"
build_tree "$t"
printf 'MEWG_GROUP="mixed-a"\n' > "$t/tests/hooks/main-enforce-worktree-guard-mixed-b.sh"
expect_fail "S7 copied entrypoint keeps another group's MEWG_GROUP" "$t" "mixed-a" "MEWG_GROUP does not match its file name: [mixed-b]"

t="$ST_TMP_ROOT/two-assign"
build_tree "$t"
printf 'MEWG_GROUP="mixed-c"\nMEWG_GROUP="mixed-c"\n' > "$t/tests/hooks/main-enforce-worktree-guard-mixed-c.sh"
expect_fail "S8 entrypoint with two MEWG_GROUP assignments" "$t" "mixed-a" "MEWG_GROUP does not match its file name: [mixed-c]"

t="$ST_TMP_ROOT/unknown"
build_tree "$t"
expect_fail "S9 unknown group argument" "$t" "nope" "FRAG3 unknown group: [nope]"

t="$ST_TMP_ROOT/bad-owner"
build_tree "$t"
expect_fail "S10 MEWG_PASS_OWNER is not a group" "$t" "mixed-a" "FRAG3 MEWG_PASS_OWNER is not a group in MEWG_TABLE: [nope]" 'MEWG_PASS_OWNER="nope"'

# run_verify <group> <fragments marked done, space separated>: mewg_group_verify in a subshell; sets OUT and OK.
run_verify() {
    local group="$1" marked="$2" f
    OUT="$(
        FRAG_DONE=""
        for f in $marked; do frag_done "$f"; done
        mewg_group_verify "$group"
        echo "OK=$MEWG_CHECKS_OK"
    )"
}

run_verify "mixed-c" "merge-gate.sh sanctioned-bypass.sh repo-resolution.sh"
if [ "$OUT" = "OK=1" ]; then pass "V1 every fragment done: no FAIL, checks ok"; else fail "V1 every fragment done: no FAIL, checks ok (out=[$OUT])"; fi

run_verify "mixed-c" "merge-gate.sh sanctioned-bypass.sh"
if printf '%s' "$OUT" | grep -qF "FAIL: FRAG2 fragment completion mismatch — sourced-but-unfinished: [repo-resolution.sh]" && printf '%s' "$OUT" | grep -qxF "OK=0"; then
    pass "V2 missing frag_done is sourced-but-unfinished"
else
    fail "V2 missing frag_done is sourced-but-unfinished (out=[$OUT])"
fi

run_verify "mixed-c" "merge-gate.sh sanctioned-bypass.sh repo-resolution.sh orphan-cwd-fail-closed.sh"
if printf '%s' "$OUT" | grep -qF "marked-but-not-sourced: [orphan-cwd-fail-closed.sh]" && printf '%s' "$OUT" | grep -qxF "OK=0"; then
    pass "V3 another group's fragment is marked-but-not-sourced"
else
    fail "V3 another group's fragment is marked-but-not-sourced (out=[$OUT])"
fi

run_verify "$MEWG_PASS_OWNER" "push-range-basic.sh"
if printf '%s' "$OUT" | grep -qF "PASS: FRAG1" && printf '%s' "$OUT" | grep -qF "PASS: FRAG2"; then
    pass "V4a pass owner group emits the FRAG1 and FRAG2 result lines"
else
    fail "V4a pass owner group emits the FRAG1 and FRAG2 result lines (out=[$OUT])"
fi
run_verify "mixed-c" "merge-gate.sh sanctioned-bypass.sh repo-resolution.sh"
if ! printf '%s' "$OUT" | grep -qF "PASS:"; then pass "V4b non-owner group emits no PASS result line"; else fail "V4b non-owner group emits no PASS result line (out=[$OUT])"; fi
run_verify "$MEWG_PASS_OWNER" ""
if ! printf '%s' "$OUT" | grep -qF "PASS:"; then pass "V4c pass owner with a failed check emits no PASS result line"; else fail "V4c pass owner with a failed check emits no PASS result line (out=[$OUT])"; fi

# E1: a failing static check makes the real entrypoint skip every fragment and exit 1.
# The tree is a copy: the entrypoint, the two libs and a stub guard file; each fragment leaves a marker.
build_entry_tree() {
    local dir="$1" entry
    build_tree "$dir"
    mkdir -p "$dir/tests/lib" "$dir/hooks"
    cp "$REAL_ROOT/tests/lib/mewg-harness.sh" "$REAL_ROOT/tests/lib/mewg-groups.sh" "$dir/tests/lib/"
    cp "$REAL_ROOT/tests/hooks/main-enforce-worktree-guard-push-range.sh" "$dir/tests/hooks/"
    : > "$dir/hooks/enforce-worktree.js"
    for entry in "${MEWG_TABLE[@]}"; do
        printf 'touch "%s/sourced-%s"\nfrag_done "%s"\n' "$dir" "${entry%%:*}" "${entry%%:*}" \
            > "$dir/tests/hooks/main-enforce-worktree-guard/${entry%%:*}"
    done
}
t="$ST_TMP_ROOT/entry-ok"
build_entry_tree "$t"
OUT="$(bash "$t/tests/hooks/main-enforce-worktree-guard-push-range.sh" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -e "$t/sourced-push-range-basic.sh" ] && printf '%s' "$OUT" | grep -qF "PASS: FRAG2"; then
    pass "E1a agreeing tree: the entrypoint sources its fragment and exits 0"
else
    fail "E1a agreeing tree: the entrypoint sources its fragment and exits 0 (rc=$RC out=[$OUT])"
fi
t="$ST_TMP_ROOT/entry-bad"
build_entry_tree "$t"
: > "$t/tests/hooks/main-enforce-worktree-guard/stray.sh"
OUT="$(bash "$t/tests/hooks/main-enforce-worktree-guard-push-range.sh" 2>&1)"
RC=$?
if [ "$RC" -eq 1 ] && [ ! -e "$t/sourced-push-range-basic.sh" ] && printf '%s' "$OUT" | grep -qF "FAIL: FRAG1 fragment set mismatch"; then
    pass "E1b failing static check: no fragment is sourced and the entrypoint exits 1"
else
    fail "E1b failing static check: no fragment is sourced and the entrypoint exits 1 (rc=$RC out=[$OUT])"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
