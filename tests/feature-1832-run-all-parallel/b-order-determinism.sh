#!/usr/bin/env bash
# b-order-determinism.sh — invariant 1: stdout does not depend on -j.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, ledger, scope:issue-specific

# WHY: under the SAME host and the SAME duration-ledger state, stdout does not depend on -j —
# output replays in submission order, not completion order. Descending sleeps make completion
# order the reverse of submission order, ruling out live/completion-order replay. Phase 1 pins
# that with an empty ledger, phase 2 with a frozen non-empty one (LPT re-orders submission,
# and the invariant must survive the re-ordering rather than depend on ledger emptiness).

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "b-order-determinism"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- phase 1: empty ledger (fx_exec clears it before every run) ------------

BLOCK_LINES=50
ROOT="$(fx_new_root)"
fx_add_dummy "$ROOT" t1 --sleep 3 --lines "$BLOCK_LINES"
fx_add_dummy "$ROOT" t2 --sleep 3 --lines "$BLOCK_LINES"
fx_add_dummy "$ROOT" t3 --sleep 2 --lines "$BLOCK_LINES"
fx_add_dummy "$ROOT" t4 --sleep 2 --lines "$BLOCK_LINES"
fx_add_dummy "$ROOT" t5 --sleep 1 --lines "$BLOCK_LINES"
fx_add_dummy "$ROOT" t6 --sleep 1 --lines "$BLOCK_LINES"

SEQ_OUT="$FX_TMP_ROOT/seq.out"; SEQ_ERR="$FX_TMP_ROOT/seq.err"
PAR_OUT="$FX_TMP_ROOT/par.out"; PAR_ERR="$FX_TMP_ROOT/par.err"

fx_exec "$ROOT" 90 "$SEQ_OUT" "$SEQ_ERR" -j 1 --all
SEQ_RC=$?
fx_exec "$ROOT" 90 "$PAR_OUT" "$PAR_ERR" -j 8 --all
PAR_RC=$?

SEQ_EXEC="$(fx_contract_field "$SEQ_OUT" EXECUTED)"
PAR_EXEC="$(fx_contract_field "$PAR_OUT" EXECUTED)"

if [ "$SEQ_EXEC" = "6" ] && [ "$PAR_EXEC" = "6" ]; then
    fx_pass "B1. both runs executed all 6 dummies (exit $SEQ_RC / $PAR_RC)"
else
    fx_fail "B1. want EXECUTED=6 at -j 1 and -j 8, got -j 1 EXECUTED=$SEQ_EXEC, -j 8 EXECUTED=$PAR_EXEC"
fi

# Invariant 1 proper. Asserted together with the executed count so that two
# equally empty runs cannot report determinism.
if [ "$SEQ_EXEC" = "6" ] && [ "$PAR_EXEC" = "6" ] && cmp -s "$SEQ_OUT" "$PAR_OUT"; then
    fx_pass "B2. empty ledger: -j 1 and -j 8 produce byte-identical stdout over 6 executed tests"
else
    fx_fail "B2. empty ledger: stdout differs between -j 1 and -j 8 (or the run was empty: EXECUTED=$SEQ_EXEC/$PAR_EXEC)"
    diff "$SEQ_OUT" "$PAR_OUT" 2>/dev/null | head -n 10 | fx_mask | sed 's/^/    | /'
fi

# Each dummy's block must appear contiguously — no interleaving of two children
# into one stretch of the parent's stdout.
INTERLEAVED=""
for id in t1 t2 t3 t4 t5 t6; do
    nums="$(grep -n "^$id line " "$PAR_OUT" 2>/dev/null | cut -d: -f1)"
    count="$(printf '%s\n' "$nums" | grep -c '[0-9]' || true)"
    if [ "$count" != "$BLOCK_LINES" ]; then
        INTERLEAVED="$INTERLEAVED $id(lines=$count)"
        continue
    fi
    first="$(printf '%s\n' "$nums" | head -n 1)"
    last="$(printf '%s\n' "$nums" | tail -n 1)"
    [ "$((last - first + 1))" -eq "$BLOCK_LINES" ] || INTERLEAVED="$INTERLEAVED $id(span=$((last - first + 1)))"
done
if [ -z "$INTERLEAVED" ]; then
    fx_pass "B3. -j 8: every dummy's $BLOCK_LINES-line block is contiguous in the parent's stdout"
else
    fx_fail "B3. -j 8: expected one contiguous $BLOCK_LINES-line block per dummy; broken for:$INTERLEAVED"
fi

# --- stderr is buffered per test, exactly like stdout ----------------------

# WHY: stdout alone can't distinguish submission-order replay from completion-order replay unless the
# orders disagree; descending sleeps force that disagreement, catching both live-write shredding and reverse replay.

ERR_BLOCK=60
IDS="e1 e2 e3 e4 e5 e6"
ORD="$(fx_new_root)"
SLEEP_S=6
for id in $IDS; do
    fx_add_dummy "$ORD" "$id" --sleep "$SLEEP_S" --lines 2 --err-lines "$ERR_BLOCK"
    SLEEP_S=$((SLEEP_S - 1))
done

ORD_OUT="$FX_TMP_ROOT/ord.out"; ORD_ERR="$FX_TMP_ROOT/ord.err"
FILTERED="$FX_TMP_ROOT/ord.err.filtered"
fx_exec "$ORD" 120 "$ORD_OUT" "$ORD_ERR" -j 6 --all
ORD_RC=$?
ORD_EXEC="$(fx_contract_field "$ORD_OUT" EXECUTED)"
grep -v '^\[run-all\] ' "$ORD_ERR" > "$FILTERED" 2>/dev/null || true

BROKEN=""
ORDER=""
for id in $IDS; do
    nums="$(grep -n "^$id err line " "$FILTERED" 2>/dev/null | cut -d: -f1)"
    count="$(printf '%s\n' "$nums" | grep -c '[0-9]' || true)"
    if [ "$count" != "$ERR_BLOCK" ]; then
        BROKEN="$BROKEN $id(lines=$count)"
        continue
    fi
    first="$(printf '%s\n' "$nums" | head -n 1)"
    last="$(printf '%s\n' "$nums" | tail -n 1)"
    [ "$((last - first + 1))" -eq "$ERR_BLOCK" ] || BROKEN="$BROKEN $id(span=$((last - first + 1)))"
    ORDER="$ORDER $first"
done

if [ "$ORD_EXEC" = "6" ] && [ -z "$BROKEN" ]; then
    fx_pass "B4. -j 6, EXECUTED=6: each child's $ERR_BLOCK-line stderr block is contiguous after progress lines are filtered"
else
    fx_fail "B4. want EXECUTED=6 with one contiguous $ERR_BLOCK-line stderr block per child, got EXECUTED=$ORD_EXEC (exit $ORD_RC) broken:${BROKEN:- none}"
fi

ASCENDING=1
PREV=0
for n in $ORDER; do
    [ "$n" -gt "$PREV" ] || ASCENDING=0
    PREV="$n"
done
COUNTED="$(printf '%s\n' $ORDER | grep -c '[0-9]' || true)"
if [ "$ORD_EXEC" = "6" ] && [ "$COUNTED" = "6" ] && [ "$ASCENDING" -eq 1 ]; then
    fx_pass "B5. EXECUTED=6: stderr blocks replay in submission order e1..e6 although completion order is e6..e1"
else
    fx_fail "B5. want EXECUTED=6 and all 6 stderr blocks in submission order e1..e6, got EXECUTED=$ORD_EXEC with $COUNTED located block(s) at offsets:${ORDER:- none}"
fi

# --- phase 2: frozen NON-empty ledger --------------------------------------

# Durations run counter to alphabetical order on purpose: glob order is d1,d2,d3,d4
# and LPT order is d3,d4,d1,d2, so an assertion on the order cannot pass by accident.
# 2 and 8 sit just above a power of two, so the +-1s SECONDS granularity cannot move
# a dummy across a floor(log2) tier boundary.
LPT="$(fx_new_root)"
fx_add_dummy "$LPT" d1 --sleep 2 --lines "$BLOCK_LINES"
fx_add_dummy "$LPT" d2 --sleep 2 --lines "$BLOCK_LINES"
fx_add_dummy "$LPT" d3 --sleep 8 --lines "$BLOCK_LINES"
fx_add_dummy "$LPT" d4 --sleep 8 --lines "$BLOCK_LINES"

FX_LEDGER_KEEP=1
SNAP="$FX_TMP_ROOT/lpt.snap"
WARM_OUT="$FX_TMP_ROOT/warm.out"; WARM_ERR="$FX_TMP_ROOT/warm.err"
PLAN_OUT="$FX_TMP_ROOT/lpt.plan"; PLAN_ERR="$FX_TMP_ROOT/lpt.plan.err"
L1_OUT="$FX_TMP_ROOT/lpt1.out"; L1_ERR="$FX_TMP_ROOT/lpt1.err"
L8_OUT="$FX_TMP_ROOT/lpt8.out"; L8_ERR="$FX_TMP_ROOT/lpt8.err"

fx_ledger_clear
fx_exec "$LPT" 90 "$WARM_OUT" "$WARM_ERR" -j 4 --all
WARM_EXEC="$(fx_contract_field "$WARM_OUT" EXECUTED)"
fx_ledger_snapshot "$SNAP"
SEGS="$(fx_ledger_segments)"

if [ "$WARM_EXEC" = "4" ] && [ "$SEGS" -ge 1 ]; then
    fx_pass "B6. warm-up executed 4 dummies and left $SEGS ledger segment(s)"
else
    fx_fail "B6. want EXECUTED=4 and at least one ledger segment, got EXECUTED=${WARM_EXEC:-(absent)} segments=$SEGS"
fi

# The byte comparison below is only meaningful if the ledger actually re-ordered the
# list: with glob order still in force, the two runs would agree for the phase-1 reason.
fx_exec "$LPT" 60 "$PLAN_OUT" "$PLAN_ERR" --print-plan --all
PLAN_ORDER="$(awk -F'\t' '$1 == "plan" { n = split($4, a, /[\/\\]/); printf "%s ", a[n] }' "$PLAN_OUT")"
if [ "$PLAN_ORDER" = "d3.sh d4.sh d1.sh d2.sh " ]; then
    fx_pass "B7. non-empty ledger: --print-plan submits longest-first (d3 d4 d1 d2), not in glob order"
else
    fx_fail "B7. want plan order 'd3.sh d4.sh d1.sh d2.sh ', got '$PLAN_ORDER'"
fi

fx_ledger_restore "$SNAP"
fx_exec "$LPT" 90 "$L1_OUT" "$L1_ERR" -j 1 --all
fx_ledger_restore "$SNAP"
fx_exec "$LPT" 90 "$L8_OUT" "$L8_ERR" -j 8 --all
FX_LEDGER_KEEP=0

L1_EXEC="$(fx_contract_field "$L1_OUT" EXECUTED)"
L8_EXEC="$(fx_contract_field "$L8_OUT" EXECUTED)"
if [ "$L1_EXEC" = "4" ] && [ "$L8_EXEC" = "4" ] && cmp -s "$L1_OUT" "$L8_OUT"; then
    fx_pass "B8. same ledger state: -j 1 and -j 8 produce byte-identical stdout over 4 executed tests"
else
    fx_fail "B8. stdout differs between -j 1 and -j 8 under a frozen ledger (EXECUTED=$L1_EXEC/$L8_EXEC)"
    diff "$L1_OUT" "$L8_OUT" 2>/dev/null | head -n 10 | fx_mask | sed 's/^/    | /'
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$PAR_OUT" 20
[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$FILTERED" 6

fx_finish
