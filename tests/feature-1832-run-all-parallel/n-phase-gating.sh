#!/usr/bin/env bash
# n-phase-gating.sh — FEATURE_644_PHASE classifies identically at any -j.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, config, scope:issue-specific

# WHY: FEATURE_644_PHASE gates PASS-vs-SKIP in the feature-644 corpus; a scrubbed
# child env would silently SKIP everything and still look green. Pinned at both
# -j 1 and -j 4, with children reporting the value they actually observed.

# Default row: with FEATURE_644_PHASE unset, the runner's own `${...:-0}` default
# must still arrive at children as a literal 0, not unset.

# RED-FIRST: `-j` isn't parsed yet, so -j 4 rows currently measure the sequential
# path or nothing at all.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n-phase-gating"

# The corpus: two always-open gates plus one gate at each of 1, 2, 3 and 5.
# Every dummy carries a gate so every dummy reports the value it observed.
NDUMMIES=6
ROOT="$(fx_new_root)"
fx_add_dummy "$ROOT" g0a --phase 0 --lines 1
fx_add_dummy "$ROOT" g0b --phase 0 --lines 1
fx_add_dummy "$ROOT" g1 --phase 1 --lines 1
fx_add_dummy "$ROOT" g2 --phase 2 --lines 1
fx_add_dummy "$ROOT" g3 --phase 3 --lines 1
fx_add_dummy "$ROOT" g5 --phase 5 --lines 1

trim() { printf '%s' "$1" | sed 's/^[[:blank:]]*//; s/[[:blank:]]*$//'; }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then fx_pass "$name: $got"
    else fx_fail "$name: want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# verdict <file> — the contract as one comparable token, so an empty run can
# never be mistaken for a correctly-classified one.
verdict() {
    printf 'PASS=%s FAIL=%s SKIP=%s EXECUTED=%s' \
        "$(fx_contract_field "$1" PASS)" "$(fx_contract_field "$1" FAIL)" \
        "$(fx_contract_field "$1" SKIP)" "$(fx_contract_field "$1" EXECUTED)"
}

# run_at <tag> <phase|@unset> <jobs-args...> — one runner invocation with
# FEATURE_644_PHASE pinned to exactly what the row declares.
run_at() {
    local tag="$1" phase="$2"; shift 2
    local out="$FX_TMP_ROOT/$tag.out"
    if [ "$phase" = "@unset" ]; then
        fx_exec "$ROOT" 90 "$out" "$FX_TMP_ROOT/$tag.err" "$@"
    else
        FEATURE_644_PHASE="$phase" fx_exec "$ROOT" 90 "$out" "$FX_TMP_ROOT/$tag.err" "$@"
    fi
    return $?
}

phase_case() {
    local name="$1" phase="$2" wpass="$3" wskip="$4" wenv="$5"
    local want seq par seen
    want="PASS=$wpass FAIL=0 SKIP=$wskip EXECUTED=$NDUMMIES"

    run_at "$name-j1" "$phase" -j 1 --all
    run_at "$name-j4" "$phase" -j 4 --all
    seq="$(verdict "$FX_TMP_ROOT/$name-j1.out")"
    par="$(verdict "$FX_TMP_ROOT/$name-j4.out")"

    assert_eq "N-$name-j1. FEATURE_644_PHASE=$phase at -j 1 over $NDUMMIES dummies" "$want" "$seq"
    assert_eq "N-$name-j4. FEATURE_644_PHASE=$phase at -j 4 over $NDUMMIES dummies" "$want" "$par"

    if [ "$seq" = "$par" ] && [ "$seq" = "$want" ]; then
        fx_pass "N-$name-same. -j 1 and -j 4 classify the corpus identically ($want)"
    else
        fx_fail "N-$name-same. want the same non-empty verdict at both widths ($want), got -j 1 '$seq' vs -j 4 '$par'"
    fi

    seen="$(grep -c "phase-env FEATURE_644_PHASE=$wenv\$" "$FX_TMP_ROOT/$name-j4.out" || true)"
    if [ "$seen" = "$NDUMMIES" ]; then
        fx_pass "N-$name-env. all $NDUMMIES children saw FEATURE_644_PHASE=$wenv under parallel dispatch"
    else
        fx_fail "N-$name-env. want all $NDUMMIES children to report FEATURE_644_PHASE=$wenv at -j 4, got $seen that did"
    fi
}

# name | phase | want-PASS | want-SKIP | value the children must observe
while IFS='|' read -r name phase wpass wskip wenv; do
    case "$name" in ''|\#*) continue ;; esac
    phase_case "$(trim "$name")" "$(trim "$phase")" "$(trim "$wpass")" \
        "$(trim "$wskip")" "$(trim "$wenv")"
done <<'TABLE'
default | @unset | 2 | 4 | 0
p0      | 0      | 2 | 4 | 0
p2      | 2      | 4 | 2 | 2
p5      | 5      | 6 | 0 | 5
TABLE

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$FX_TMP_ROOT/p2-j4.out" 14

fx_finish
