#!/usr/bin/env bash
# l-deadline.sh — an aborted run must not be mistakable for a finished one.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY: an aborted run must not print `RUN_CONTRACT:`/`Results:` or downstream
# parsers would read a partial suite as complete and report green. Distinguished
# by exit code 3 and silence on stdout.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "l-deadline"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- (a) the deadline trips ------------------------------------------------
SLOW="$(fx_new_root)"
fx_add_dummy "$SLOW" d1 --sleep 30 --lines 1 --grandchild
fx_add_dummy "$SLOW" d2 --sleep 30 --lines 1 --grandchild
fx_add_dummy "$SLOW" d3 --sleep 30 --lines 1

OUT="$FX_TMP_ROOT/trip.out"
ERR="$FX_TMP_ROOT/trip.err"
T0="$(fx_now_ms)"
fx_exec "$SLOW" 90 "$OUT" "$ERR" --deadline 3 -j 4 --all
TRIP_RC=$?
T1="$(fx_now_ms)"
TRIP_MS=$((T1 - T0))

if [ "$TRIP_RC" -eq 3 ] && [ "$TRIP_MS" -lt 20000 ]; then
    fx_pass "L-a1. --deadline 3 against 30s of work aborted with exit 3 after ${TRIP_MS}ms"
else
    fx_fail "L-a1. want exit 3 within 20000ms, got exit $TRIP_RC after ${TRIP_MS}ms"
fi

grep -qi 'deadline' "$ERR"
fx_check $? "L-a2. the abort is explained on stderr (the message names the deadline)"

N_CONTRACT="$(fx_count_contract "$OUT")"
N_RESULTS="$(grep -cE '^Results:' "$OUT" || true)"
if [ "$N_CONTRACT" = "0" ] && [ "$N_RESULTS" = "0" ] && [ "$TRIP_RC" -eq 3 ]; then
    fx_pass "L-a3. an aborted run prints neither a contract line nor a Results: line on stdout"
else
    fx_fail "L-a3. want 0 contract and 0 Results: lines on an exit-3 abort, got contract=$N_CONTRACT results=$N_RESULTS exit=$TRIP_RC"
fi

TRIP_PIDS="$(fx_recorded_pids "$SLOW")"
if [ -z "$TRIP_PIDS" ]; then
    fx_fail "L-a4. no test process was ever recorded, so deadline teardown is unverifiable (the run never started 3 children)"
elif fx_wait_gone 10 $TRIP_PIDS; then
    fx_pass "L-a4. every test process and spawned grandchild is gone 10s after the deadline abort"
else
    fx_fail "L-a4. processes survived the deadline abort (pids: $(echo $TRIP_PIDS | tr '\n' ' '))"
fi

# --- (b) an unusable deadline is refused before anything runs --------------
QUICK="$(fx_new_root)"
fx_add_dummy "$QUICK" q1 --lines 1
fx_add_dummy "$QUICK" q2 --lines 1

expect_refused() {
    local label="$1"; shift
    local out="$FX_TMP_ROOT/refused.out"
    local rc n
    if [ "$1" = "--env" ]; then
        shift
        RUN_ALL_DEADLINE="$1" fx_exec "$QUICK" 30 "$out" "$FX_TMP_ROOT/refused.err" --all
        rc=$?
    else
        fx_exec "$QUICK" 30 "$out" "$FX_TMP_ROOT/refused.err" "$@"
        rc=$?
    fi
    n="$(fx_count_contract "$out")"
    if [ "$rc" -eq 2 ] && [ "$n" = "0" ]; then
        fx_pass "L-b. $label -> exit 2 with no contract line"
    else
        fx_fail "L-b. $label -> want exit 2 and 0 contract lines, got exit $rc with $n contract line(s)"
    fi
}

expect_refused "--deadline 0"          --deadline 0 --all
expect_refused "--deadline abc"        --deadline abc --all
expect_refused "--deadline (no value)" --deadline
expect_refused "RUN_ALL_DEADLINE=abc"  --env abc
expect_refused "RUN_ALL_DEADLINE=-5"   --env -5

# --- (c) the env spelling is the flag --------------------------------------
ENV_OUT="$FX_TMP_ROOT/env.out"
T2="$(fx_now_ms)"
RUN_ALL_DEADLINE=3 fx_exec "$SLOW" 90 "$ENV_OUT" "$FX_TMP_ROOT/env.err" -j 4 --all
ENV_RC=$?
T3="$(fx_now_ms)"
ENV_MS=$((T3 - T2))
ENV_CONTRACT="$(fx_count_contract "$ENV_OUT")"
if [ "$ENV_RC" -eq 3 ] && [ "$ENV_MS" -lt 20000 ] && [ "$ENV_CONTRACT" = "0" ]; then
    fx_pass "L-c. RUN_ALL_DEADLINE=3 behaves exactly like --deadline 3 (exit 3, no contract, ${ENV_MS}ms)"
else
    fx_fail "L-c. want the env spelling to abort like the flag, got exit $ENV_RC after ${ENV_MS}ms with $ENV_CONTRACT contract line(s)"
fi

# --- (d) a deadline that is never reached changes nothing ------------------
OK_OUT="$FX_TMP_ROOT/ok.out"
fx_exec "$QUICK" 60 "$OK_OUT" "$FX_TMP_ROOT/ok.err" --deadline 60 -j 4 --all
OK_RC=$?
OK_EXEC="$(fx_contract_field "$OK_OUT" EXECUTED)"
OK_PASS="$(fx_contract_field "$OK_OUT" PASS)"
if [ "$OK_EXEC" = "2" ] && [ "$OK_PASS" = "2" ] && [ "$OK_RC" -eq 0 ]; then
    fx_pass "L-d. a deadline that is never reached leaves the normal contract and exit 0 intact"
else
    fx_fail "L-d. want EXECUTED=2 PASS=2 exit 0 under --deadline 60, got EXECUTED=$OK_EXEC PASS=$OK_PASS exit $OK_RC"
fi

# --- (e) mixed suite: some tests finish, one hangs past the deadline -------

# The dangerous case: 3 tests really did pass, so there's a genuine partial tally
# an implementation could wrongly print. Held to the same contract as (a): exit 3,
# no RUN_CONTRACT/Results, no verdict for a test that never finished.

MIX="$(fx_new_root)"
fx_add_dummy "$MIX" f1 --lines 1
fx_add_dummy "$MIX" f2 --lines 1
fx_add_dummy "$MIX" f3 --lines 1
fx_add_dummy "$MIX" h1 --sleep 30 --lines 1 --grandchild
fx_add_dummy "$MIX" h2 --sleep 30 --lines 1

MIX_OUT="$FX_TMP_ROOT/mix.out"
MIX_ERR="$FX_TMP_ROOT/mix.err"
T4="$(fx_now_ms)"
fx_exec "$MIX" 90 "$MIX_OUT" "$MIX_ERR" --deadline 4 -j 4 --all
MIX_RC=$?
T5="$(fx_now_ms)"
MIX_MS=$((T5 - T4))

# How many of the three fast dummies actually got to run, from their own
# self-recorded pid files — the execution evidence every claim below carries.
DONE=0
for id in f1 f2 f3; do [ -f "$MIX/pids/$id.self" ] && DONE=$((DONE + 1)); done

MIX_CONTRACT="$(fx_count_contract "$MIX_OUT")"
MIX_RESULTS="$(grep -cE '^Results:' "$MIX_OUT" || true)"
MIX_VERDICTS="$(grep -cE '^(PASS|FAIL|SKIP): ' "$MIX_OUT" || true)"
MIX_HUNG="$(grep -cE '^(PASS|FAIL|SKIP): .*/h[12]\.sh' "$MIX_OUT" || true)"

if [ "$DONE" = "3" ] && [ "$MIX_RC" -eq 3 ] && [ "$MIX_MS" -lt 20000 ]; then
    fx_pass "L-e1. 3 of 5 tests completed and 2 hung: --deadline 4 still aborted with exit 3 after ${MIX_MS}ms"
else
    fx_fail "L-e1. want 3 completed dummies and exit 3 within 20000ms, got completed=$DONE exit $MIX_RC after ${MIX_MS}ms"
fi

if [ "$DONE" = "3" ] && [ "$MIX_CONTRACT" = "0" ] && [ "$MIX_RESULTS" = "0" ]; then
    fx_pass "L-e2. 3 completed tests do not earn a summary: the mixed abort prints neither a contract nor a Results: line"
else
    fx_fail "L-e2. want 3 completed dummies with 0 contract and 0 Results: lines on a mixed abort, got completed=$DONE contract=$MIX_CONTRACT results=$MIX_RESULTS"
fi

if [ "$DONE" = "3" ] && grep -qi 'deadline' "$MIX_ERR"; then
    fx_pass "L-e3. 3 completed tests: the mixed abort is still explained on stderr"
else
    fx_fail "L-e3. want 3 completed dummies and a deadline message on stderr, got completed=$DONE"
fi

if [ "$DONE" = "3" ] && [ "$MIX_HUNG" = "0" ] && [ "$MIX_VERDICTS" -le 3 ]; then
    fx_pass "L-e4. 3 completed tests: no verdict line is claimed for either hung test ($MIX_VERDICTS verdict line(s), none naming h1/h2)"
else
    fx_fail "L-e4. want 3 completed dummies, 0 verdict lines naming h1/h2 and at most 3 verdict lines, got completed=$DONE hung-verdicts=$MIX_HUNG total=$MIX_VERDICTS"
fi

MIX_PIDS="$(fx_recorded_pids "$MIX")"
if [ "$DONE" != "3" ]; then
    fx_fail "L-e5. only $DONE of the 3 fast dummies ran, so mixed-abort teardown is unverifiable"
elif fx_wait_gone 10 $MIX_PIDS; then
    fx_pass "L-e5. 3 completed tests: the hung tests and their grandchild are gone 10s after the mixed abort"
else
    fx_fail "L-e5. processes survived the mixed abort (pids: $(echo $MIX_PIDS | tr '\n' ' '))"
fi

fx_note "mixed complete+hang is held to the SAME abort contract as (a) — partial success never promotes an aborted run to a reportable one"

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$ERR" 20

fx_finish
