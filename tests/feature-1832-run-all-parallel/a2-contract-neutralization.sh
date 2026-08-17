#!/usr/bin/env bash
# a2-contract-neutralization.sh — W-NEUTRALIZE over the whole input domain.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY: two downstream parsers read the runner's output under an exactly-one rule.
# hooks/workflow-run-tests.js scans the parent's STDOUT; the worker in
# bin/worker-dispatch/workers/test-runner.js CONCATENATES stdout and stderr
# first. A child test that prints a contract-shaped line therefore forges a
# second match on either surface unless the parent neutralizes both replays.

# The dummies cover the whole shape the two regexes accept: on stdout, on
# stderr, and leading-whitespace-indented (both patterns carry `^[ \t]*`).

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "a2-contract-neutralization"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

ROOT="$(fx_new_root)"
fx_add_dummy "$ROOT" c1-stdout   --contract stdout   --lines 1
fx_add_dummy "$ROOT" c2-stderr   --contract stderr   --lines 1
fx_add_dummy "$ROOT" c3-indented --contract indented --lines 1

NEUTRAL_PREFIX='[run-all:neutralized] '

check_run() {
    local jobs="$1"
    local out="$FX_TMP_ROOT/j$jobs.out" err="$FX_TMP_ROOT/j$jobs.err"
    fx_exec "$ROOT" 60 "$out" "$err" -j "$jobs" --all
    local executed n_out n_cat
    executed="$(fx_contract_field "$out" EXECUTED)"
    n_out="$(fx_count_contract "$out")"
    n_cat="$(fx_count_contract "$out" "$err")"

    if [ "$executed" = "3" ] && [ "$n_out" = "1" ]; then
        fx_pass "N-$jobs-a. -j $jobs: 3 contract-forging tests ran; hook CONTRACT_SCAN_RE matches stdout exactly once"
    else
        fx_fail "N-$jobs-a. -j $jobs: want EXECUTED=3 with exactly 1 contract match on stdout, got EXECUTED=$executed matches=$n_out"
    fi

    if [ "$executed" = "3" ] && [ "$n_cat" = "1" ]; then
        fx_pass "N-$jobs-b. -j $jobs: worker CONTRACT_LINE_RE matches stdout+stderr concatenated exactly once"
    else
        fx_fail "N-$jobs-b. -j $jobs: want EXECUTED=3 with exactly 1 contract match over stdout+stderr, got EXECUTED=$executed matches=$n_cat"
    fi
}

check_run 1
check_run 4

# (c) neutralization PREFIXES, it does not rewrite: the child's original bytes
# must still be there, indentation included.
OUT4="$FX_TMP_ROOT/j4.out"
ERR4="$FX_TMP_ROOT/j4.err"
PLAIN="RUN_CONTRACT: PASS=9 FAIL=9 SKIP=9 EXECUTED=9"

grep -qF "${NEUTRAL_PREFIX}${PLAIN}" "$OUT4"
fx_check $? "N-c1. stdout replay keeps the child's bytes after '${NEUTRAL_PREFIX}'"

grep -qF "${NEUTRAL_PREFIX}${PLAIN}" "$ERR4"
fx_check $? "N-c2. stderr replay keeps the child's bytes after '${NEUTRAL_PREFIX}'"

grep -qF "${NEUTRAL_PREFIX}$(printf '\t')  ${PLAIN}" "$OUT4"
fx_check $? "N-c3. an indented contract-shaped line keeps its leading tab+spaces after the prefix"

# --- negative control ------------------------------------------------------
# A doctored copy with the neutralization removed must fail (a) and (b). Built
# by sed on the fixture's copy — the real runner is never edited.
DOCTORED="$ROOT/bin/run-all-doctored.sh"
if fx_doctor_runner "$ROOT" "$DOCTORED"; then
    D_OUT="$FX_TMP_ROOT/doctored.out"
    D_ERR="$FX_TMP_ROOT/doctored.err"
    TESTS_DIR="$(fx_tests_dir "$ROOT")" RUN_ALL_CACHE_DIR="$FX_CACHE_DIR" \
        run_with_timeout 60 bash "$DOCTORED" -j 4 --all >"$D_OUT" 2>"$D_ERR"
    D_OUT_N="$(fx_count_contract "$D_OUT")"
    D_CAT_N="$(fx_count_contract "$D_OUT" "$D_ERR")"
    if [ "$D_OUT_N" -gt 1 ] && [ "$D_CAT_N" -gt 1 ]; then
        fx_pass "N-neg. negative control: removing neutralization breaks both parsers (stdout=$D_OUT_N, concat=$D_CAT_N)"
    else
        fx_fail "N-neg. negative control did not break: want >1 match on both surfaces, got stdout=$D_OUT_N concat=$D_CAT_N"
    fi
else
    fx_fail "N-neg. cannot build the negative control: tests/run-all.sh has no 'neutralize_stream <file>' call site (W-NEUTRALIZE absent)"
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$OUT4" 20

fx_finish
