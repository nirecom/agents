#!/usr/bin/env bash
# n4-duration-ledger-worktree.sh — measurements are shared across linked git worktrees.
# Tests: bin/lib/run-all-durations.sh, tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, git-worktree, TL2, scope:issue-specific

# WHY: the repo identifier keys the ledger on the repository, not on the worktree path, so a
# measurement taken in one worktree is reused in every sibling. A real `git worktree add` is
# the only fixture that exercises the relative-vs-absolute --git-common-dir asymmetry.

# TL3 gap (what this test does NOT catch):
# - a host without git, where this file skips entirely (exit 77)
# - submodules and `--separate-git-dir` layouts, neither of which this repo uses
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable" >&2; exit 77; }

fx_init "n4-duration-ledger-worktree"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

LIB_OK=0
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    command -v run_all_dur_repo_id >/dev/null 2>&1 && LIB_OK=1
fi

lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: $DUR_LIB_REL)"
    return 0
}

UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"

# The value is memoized in RUN_ALL_DUR_REPO_ID, so each probe runs in its own subshell
# with the memo cleared — otherwise every directory would trivially "agree".
repo_id_of() {
    (
        RUN_ALL_DUR_REPO_ID=""
        v="$(run_all_dur_repo_id "$1" 2>/dev/null || true)"
        [ -n "$v" ] || v="${RUN_ALL_DUR_REPO_ID:-}"
        printf '%s' "$v"
    )
}

plan_tier() {
    awk -F'\t' -v b="$2" \
        '$1 == "plan" { n = split($4, a, /[\/\\]/); if (a[n] == b) { print $5; exit } }' "$1"
}

ROOT="$(fx_new_git_root)" || { echo "SKIP: cannot build a git fixture repository" >&2; exit 77; }

fx_add_dummy "$ROOT" w1 --sleep 2
fx_add_dummy "$ROOT" w2 --sleep 8
git -C "$ROOT" add -A >/dev/null 2>&1
git -C "$ROOT" commit -q -m "dummies" >/dev/null 2>&1 || {
    echo "SKIP: cannot commit the git fixture" >&2; exit 77; }

LINK="$FX_TMP_ROOT/linked-worktree"
git -C "$ROOT" worktree add -q -b fx-link "$LINK" >/dev/null 2>&1 || {
    echo "SKIP: git worktree add unavailable" >&2; exit 77; }
[ -f "$(fx_runner "$LINK")" ] || { echo "SKIP: linked worktree has no runner copy" >&2; exit 77; }

# ===========================================================================
# N13a/N13c — one id per repository, and it is not a constant
# ===========================================================================
UNRELATED="$FX_TMP_ROOT/unrelated-non-git"
mkdir -p "$UNRELATED"

if lib_missing "N13a. main and linked worktree share one repo id"; then
    fx_fail "N13c. an unrelated non-git root gets a different repo id (implementation missing: $DUR_LIB_REL)"
else
    ID_MAIN="$(repo_id_of "$ROOT")"
    ID_LINK="$(repo_id_of "$LINK")"
    ID_OTHER="$(repo_id_of "$UNRELATED")"
    if [ -n "$ID_MAIN" ] && [ "$ID_MAIN" = "$ID_LINK" ]; then
        fx_pass "N13a. main and linked worktree both resolve repo id $ID_MAIN"
    else
        fx_fail "N13a. want one shared repo id, got main='${ID_MAIN:-empty}' linked='${ID_LINK:-empty}'"
    fi
    # Without this, N13a would also pass for a function that returns a constant.
    if [ -n "$ID_OTHER" ] && [ "$ID_OTHER" != "$ID_MAIN" ]; then
        fx_pass "N13c. an unrelated non-git root resolves a different id ($ID_OTHER)"
    else
        fx_fail "N13c. want an id different from '$ID_MAIN' for an unrelated root, got '${ID_OTHER:-empty}'"
    fi
fi

# ===========================================================================
# N13b — a measurement taken in the main worktree is visible from the linked one
# ===========================================================================
W_OUT="$FX_TMP_ROOT/w.out"; W_ERR="$FX_TMP_ROOT/w.err"
P_OUT="$FX_TMP_ROOT/wp.out"; P_ERR="$FX_TMP_ROOT/wp.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$ROOT" 120 "$W_OUT" "$W_ERR" -j 2 --all
W_EXEC="$(fx_contract_field "$W_OUT" EXECUTED)"

fx_exec "$LINK" 60 "$P_OUT" "$P_ERR" --print-plan --all
RC=$?
T1="$(plan_tier "$P_OUT" w1.sh)"
T2="$(plan_tier "$P_OUT" w2.sh)"
FX_LEDGER_KEEP=0

P_ROWS="$(grep -c '^plan	' "$P_OUT" || true)"
if [ "$W_EXEC" = "2" ] && [ "$RC" -eq 0 ] && [ "$P_ROWS" = "2" ]; then
    fx_pass "N13d. the fixture is real: 2 dummies ran in the main worktree, 2 planned in the linked one"
else
    fx_fail "N13d. the worktree fixture is not usable — want EXECUTED=2 and 2 plan rows from the linked worktree, got EXECUTED=${W_EXEC:-absent} exit $RC rows=$P_ROWS"
    fx_show_tail "$P_ERR" 6
fi

if lib_missing "N13b. the linked worktree reads the main worktree's measurements"; then :
elif [ "$W_EXEC" = "2" ] && [ "$RC" -eq 0 ] && [ "$T1" = "1" ] && [ "$T2" = "3" ]; then
    fx_pass "N13b. the linked worktree reported w1 tier 1 and w2 tier 3 from the main worktree's run"
elif [ "$T1" = "$UNMEASURED" ] || [ "$T2" = "$UNMEASURED" ]; then
    fx_fail "N13b. the linked worktree saw unmeasured tiers (w1=$T1 w2=$T2) — the ledger did not cross the worktree boundary"
else
    fx_fail "N13b. want EXECUTED=2, exit 0, w1 tier 1 and w2 tier 3, got EXECUTED=${W_EXEC:-absent} exit $RC w1='${T1:-absent}' w2='${T2:-absent}'"
fi

git -C "$ROOT" worktree remove --force "$LINK" >/dev/null 2>&1 || true

fx_finish
