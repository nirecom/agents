#!/usr/bin/env bash
# n2-duration-ledger-order.sh — the plan surface: LPT order, tier field, serial pinning, degradation.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: the ledger only pays off if the plan actually re-orders, and only stays safe if every
# ledger failure lands on "everything unmeasured, current order" instead of a crash or a
# degraded -j. Writer-side cases live in n-, reader cases in n3-, worktree sharing in n4-.

# TL3 gap (what this test does NOT catch):
# - a loaded host where the +-1s SECONDS granularity moves a dummy across a tier boundary
# - the real 843-test corpus, where tier ties are the common case rather than the exception
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n2-duration-ledger-order"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

# Every row names the absent implementation instead of crashing (RED-FIRST).
dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

UNMEASURED=99
if [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
fi
if [ -f "$DUR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"
fi

# plan\t<idx>\t<lane>\t<path>\t<tier> — the tier is the field this issue adds.
plan_names() {
    awk -F'\t' '$1 == "plan" { n = split($4, a, /[\/\\]/); printf "%s ", a[n] }' "$1"
}
plan_field() {
    awk -F'\t' -v b="$2" -v f="$3" \
        '$1 == "plan" { n = split($4, a, /[\/\\]/); if (a[n] == b) { print $f; exit } }' "$1"
}
plan_tier() { plan_field "$1" "$2" 5; }
plan_idx() { plan_field "$1" "$2" 2; }
plan_serial_count() { sed -n 's/^serial_count=\([0-9][0-9]*\)$/\1/p' "$1" | head -n 1; }

# Rows whose tier differs from the tier expected for that basename, as "<base>(want=..got=..)".
tier_mismatches() {
    local plan="$1" base want got out=""
    while IFS='|' read -r base want; do
        [ -n "$base" ] || continue
        got="$(plan_tier "$plan" "$base")"
        [ "$got" = "$want" ] || out="$out $base(want=$want got=${got:-absent})"
    done
    printf '%s' "$out"
}

# ===========================================================================
# N4 — longest-first order, and the tier travels with the row
# ===========================================================================

# Durations run counter to alphabetical order so LPT order cannot coincide with glob order.
# 2/4/8 sit on tier boundaries 1/2/3 with a whole tier of headroom for +-1s jitter.
Z="$(fx_new_root)"
fx_add_dummy "$Z" z1 --sleep 2
fx_add_dummy "$Z" z2 --sleep 8
fx_add_dummy "$Z" z3 --sleep 4

Z_OUT="$FX_TMP_ROOT/z.out"; Z_ERR="$FX_TMP_ROOT/z.err"
ZP_OUT="$FX_TMP_ROOT/zp.out"; ZP_ERR="$FX_TMP_ROOT/zp.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$Z" 120 "$Z_OUT" "$Z_ERR" -j 3 --all
Z_EXEC="$(fx_contract_field "$Z_OUT" EXECUTED)"
fx_exec "$Z" 60 "$ZP_OUT" "$ZP_ERR" --print-plan --all
Z_ORDER="$(plan_names "$ZP_OUT")"

Z_ROWS="$(grep -c '^plan	' "$ZP_OUT" || true)"
if [ "$Z_EXEC" = "3" ] && [ "$Z_ROWS" = "3" ]; then
    fx_pass "N4c. the warm-up fixture is real: 3 dummies executed and 3 plan rows printed"
else
    fx_fail "N4c. the warm-up fixture is not usable — want EXECUTED=3 and 3 plan rows, got EXECUTED=${Z_EXEC:-absent} rows=$Z_ROWS"
    fx_show_tail "$Z_ERR" 6
fi

if dur_missing "N4. warm ledger puts the longest test first"; then :
elif [ "$Z_EXEC" = "3" ] && [ "$Z_ORDER" = "z2.sh z3.sh z1.sh " ]; then
    fx_pass "N4. after a warm-up the plan is z2 (8s), z3 (4s), z1 (2s) — not glob order"
else
    fx_fail "N4. want EXECUTED=3 and plan order 'z2.sh z3.sh z1.sh ', got EXECUTED=${Z_EXEC:-(absent)} order='$Z_ORDER'"
fi

# C7: the tier must be written back through the same path as the work item. If only WORK
# moved, the order above would still pass while every tier stayed on the old index.
Z_BAD="$(tier_mismatches "$ZP_OUT" <<EOF
z1.sh|1
z3.sh|2
z2.sh|3
EOF
)"
if dur_missing "N4b. each plan row carries the tier of its own path"; then :
elif [ -z "$Z_BAD" ]; then
    fx_pass "N4b. every plan row's tier matches the tier expected from its own path (z1=1 z3=2 z2=3)"
else
    fx_fail "N4b. tier left behind on the pre-sort index:$Z_BAD"
fi

# ===========================================================================
# N20 — a second warm run neither re-orders nor merges segments
# ===========================================================================
Z2_OUT="$FX_TMP_ROOT/z2.out"; Z2_ERR="$FX_TMP_ROOT/z2.err"
ZQ_OUT="$FX_TMP_ROOT/zq.out"; ZQ_ERR="$FX_TMP_ROOT/zq.err"
fx_exec "$Z" 120 "$Z2_OUT" "$Z2_ERR" -j 3 --all
fx_exec "$Z" 60 "$ZQ_OUT" "$ZQ_ERR" --print-plan --all
Z2_ORDER="$(plan_names "$ZQ_OUT")"
Z2_SEGS="$(fx_ledger_segments)"

if dur_missing "N20. re-running over a warm ledger is idempotent in order and segment count"; then :
elif [ "$Z2_ORDER" = "$Z_ORDER" ] && [ "$Z2_SEGS" = "2" ]; then
    fx_pass "N20. the second warm run kept the plan order and left one segment per run (2 total)"
else
    fx_fail "N20. want the order unchanged from '$Z_ORDER' and 2 segments after 2 runs, got order='$Z2_ORDER' segments=$Z2_SEGS"
fi

# ===========================================================================
# N5 — a test the ledger has never seen leads the plan
# ===========================================================================
fx_add_dummy "$Z" z0 --sleep 1
N5_OUT="$FX_TMP_ROOT/n5.out"; N5_ERR="$FX_TMP_ROOT/n5.err"
fx_exec "$Z" 60 "$N5_OUT" "$N5_ERR" --print-plan --all
N5_TIER="$(plan_tier "$N5_OUT" z0.sh)"
N5_IDX="$(plan_idx "$N5_OUT" z0.sh)"
N5_NEXT="$(plan_idx "$N5_OUT" z2.sh)"

if dur_missing "N5. a newly added test is unmeasured and goes first"; then :
elif [ "$N5_TIER" = "$UNMEASURED" ] && [ "$N5_IDX" = "0" ] && [ "$N5_NEXT" = "1" ]; then
    fx_pass "N5. the new dummy reports tier $UNMEASURED at index 0, ahead of every measured test"
else
    fx_fail "N5. want tier=$UNMEASURED idx=0 for z0 and idx=1 for z2, got tier=${N5_TIER:-absent} idx=${N5_IDX:-absent} z2-idx=${N5_NEXT:-absent}"
fi

# ===========================================================================
# N6 — the serial lane is pinned to its absolute index
# ===========================================================================
M="$(fx_new_root)"
fx_add_dummy "$M" m1 --sleep 2
fx_add_dummy "$M" m2 --sleep 2
fx_add_dummy "$M" m3 --serial "ledger fixture: pinned position"
fx_add_dummy "$M" m4 --sleep 8
fx_add_dummy "$M" m5 --sleep 8

M0_OUT="$FX_TMP_ROOT/m0.out"; M0_ERR="$FX_TMP_ROOT/m0.err"
M_OUT="$FX_TMP_ROOT/m.out"; M_ERR="$FX_TMP_ROOT/m.err"
MP_OUT="$FX_TMP_ROOT/mp.out"; MP_ERR="$FX_TMP_ROOT/mp.err"

fx_ledger_clear
fx_exec "$M" 60 "$M0_OUT" "$M0_ERR" --print-plan --all
M0_IDX="$(plan_idx "$M0_OUT" m3.sh)"
M0_SER="$(plan_serial_count "$M0_OUT")"

fx_exec "$M" 120 "$M_OUT" "$M_ERR" -j 4 --all
M_EXEC="$(fx_contract_field "$M_OUT" EXECUTED)"
fx_exec "$M" 60 "$MP_OUT" "$MP_ERR" --print-plan --all
M_ORDER="$(plan_names "$MP_OUT")"
M_IDX="$(plan_idx "$MP_OUT" m3.sh)"
M_SER="$(plan_serial_count "$MP_OUT")"

if dur_missing "N6. the serial dummy keeps its index while parallel ones re-order"; then :
elif [ "$M_EXEC" = "5" ] && [ "$M0_IDX" = "2" ] && [ "$M_IDX" = "2" ] && \
     [ "$M_ORDER" = "m4.sh m5.sh m3.sh m1.sh m2.sh " ]; then
    fx_pass "N6. m3 stayed at index 2 while the parallel slots became m4 m5 / m1 m2"
else
    fx_fail "N6. want EXECUTED=5, m3 at index 2 before and after, order 'm4.sh m5.sh m3.sh m1.sh m2.sh ', got EXECUTED=${M_EXEC:-absent} idx=${M0_IDX:-absent}->${M_IDX:-absent} order='$M_ORDER'"
fi

if [ "$M0_SER" = "1" ] && [ "$M_SER" = "1" ]; then
    fx_pass "N6b. serial_count is 1 both before and after the ledger re-order"
else
    fx_fail "N6b. want serial_count=1 on both plans, got '${M0_SER:-absent}' then '${M_SER:-absent}'"
fi
FX_LEDGER_KEEP=0

# ===========================================================================
# N16 — --print-plan survives every ledger-unavailable route with tier 99
# ===========================================================================
S="$(fx_new_root)"
fx_add_dummy "$S" p1
fx_add_dummy "$S" p2
S_OUT="$FX_TMP_ROOT/s.out"; S_ERR="$FX_TMP_ROOT/s.err"

fx_exec "$S" 60 "$S_OUT" "$S_ERR" --print-plan "$(fx_tests_dir "$S")/p1.sh"
RC=$?
S_TIER="$(plan_tier "$S_OUT" p1.sh)"
S_ROWS="$(grep -c '^plan	' "$S_OUT" || true)"
if [ "$RC" -eq 0 ] && [ "$S_ROWS" = "1" ] && [ "$S_TIER" = "$UNMEASURED" ]; then
    fx_pass "N16a. --print-plan over a single named test exits 0 with tier $UNMEASURED"
else
    fx_fail "N16a. want exit 0, one plan row, tier $UNMEASURED, got exit $RC rows=$S_ROWS tier='${S_TIER:-absent}'"
    fx_show_tail "$S_ERR" 6
fi

export RUN_ALL_DURATIONS_LIB="$FX_TMP_ROOT/no-such-durations-lib.sh"
fx_exec "$S" 60 "$S_OUT" "$S_ERR" --print-plan --all
RC=$?
S_ROWS="$(grep -c '^plan	' "$S_OUT" || true)"
S_99="$(awk -F'\t' -v u="$UNMEASURED" '$1 == "plan" && $5 == u { n++ } END { print n + 0 }' "$S_OUT")"
if [ "$RC" -eq 0 ] && [ "$S_ROWS" = "2" ] && [ "$S_99" = "2" ]; then
    fx_pass "N16b. a missing RUN_ALL_DURATIONS_LIB leaves --print-plan at exit 0 with every tier $UNMEASURED"
else
    fx_fail "N16b. want exit 0 and 2 plan rows all at tier $UNMEASURED, got exit $RC rows=$S_ROWS at-unmeasured=$S_99"
    fx_show_tail "$S_ERR" 6
fi
unset RUN_ALL_DURATIONS_LIB

FX_LEDGER_KEEP=1
fx_ledger_clear
printf 'not a directory\n' > "$(fx_ledger_dir)"
fx_exec "$S" 60 "$S_OUT" "$S_ERR" --print-plan --all
RC=$?
S_ROWS="$(grep -c '^plan	' "$S_OUT" || true)"
S_99="$(awk -F'\t' -v u="$UNMEASURED" '$1 == "plan" && $5 == u { n++ } END { print n + 0 }' "$S_OUT")"
if [ "$RC" -eq 0 ] && [ "$S_ROWS" = "2" ] && [ "$S_99" = "2" ]; then
    fx_pass "N16c. a blocked durations/ path leaves --print-plan at exit 0 with every tier $UNMEASURED"
else
    fx_fail "N16c. want exit 0 and 2 plan rows all at tier $UNMEASURED, got exit $RC rows=$S_ROWS at-unmeasured=$S_99"
    fx_show_tail "$S_ERR" 6
fi
rm -f "$(fx_ledger_dir)" 2>/dev/null || true
FX_LEDGER_KEEP=0

# ===========================================================================
# N17 — a broken ledger must not cost the cached parallelism
# ===========================================================================
CONF="$FX_CACHE_DIR/parallelism.conf"
HOST=""; BUCKET=""
if command -v run_all_host_id >/dev/null 2>&1; then
    HOST="$(run_all_host_id)"
    BUCKET="$(run_all_corpus_bucket "$(fx_tests_dir "$S")")"
fi
{
    printf 'schema=1\n'
    printf 'host_id=%s\n' "$HOST"
    printf 'count_bucket=%s\n' "$BUCKET"
    printf 'jobs=6\n'
    printf 'measured_at=2026-01-01T00:00:00Z\n'
    printf 'sample_size=24\n'
    printf 'repeat=3\n'
} > "$CONF"

export RUN_ALL_DURATIONS_LIB="$FX_TMP_ROOT/no-such-durations-lib.sh"
fx_exec "$S" 60 "$S_OUT" "$S_ERR" --print-plan --all
RC=$?
unset RUN_ALL_DURATIONS_LIB

CACHED=0; DEGRADED=0
grep -qE '^\[run-all\] parallelism: -j [0-9]+ \(calibrated ' "$S_ERR" && CACHED=1
grep -q 'parallelism cache' "$S_ERR" && DEGRADED=1
if [ -z "$HOST" ]; then
    fx_fail "N17. cannot build a valid parallelism.conf: run_all_host_id unavailable from $PAR_LIB"
elif [ "$RC" -eq 0 ] && [ "$CACHED" = "1" ] && [ "$DEGRADED" = "0" ]; then
    fx_pass "N17. a missing ledger library still reports the cached -j, with no cache-missing degradation"
else
    fx_fail "N17. want exit 0 with 'parallelism: -j N (calibrated ...)' and no 'parallelism cache' line, got exit $RC cached=$CACHED degraded=$DEGRADED"
    fx_show_tail "$S_ERR" 6
fi
rm -f "$CONF" 2>/dev/null || true

fx_finish
