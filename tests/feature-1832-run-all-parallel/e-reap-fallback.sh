#!/usr/bin/env bash
# e-reap-fallback.sh — the fifo reaper is a real equal of `wait -n`.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY: `wait -n` is bash 4.3+, and on some builds it returns for a job that was
# already reaped, so the scheduler needs a fallback. A fallback is only safe if
# it is indistinguishable from the primary: same stdout, same verdict, same
# blocking behaviour. The dangerous cheap fallback is a poll loop — it looks
# correct and quietly burns a core, which is the opposite of this issue's goal.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "e-reap-fallback"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# --- E1: the two reapers, and `auto`, agree byte for byte ------------------
EQ="$(fx_new_root)"
fx_add_dummy "$EQ" r1 --sleep 2 --lines 3
fx_add_dummy "$EQ" r2 --sleep 1 --lines 3 --exit 77
fx_add_dummy "$EQ" r3 --sleep 2 --lines 3 --exit 4
fx_add_dummy "$EQ" r4 --sleep 1 --lines 3
fx_add_dummy "$EQ" r5 --sleep 2 --lines 3
fx_add_dummy "$EQ" r6 --sleep 1 --lines 3

for mode in waitn fifo auto; do
    RUN_ALL_REAP="$mode" fx_exec "$EQ" 90 "$FX_TMP_ROOT/$mode.out" "$FX_TMP_ROOT/$mode.err" -j 3 --all
    eval "RC_$mode=\$?"
done

W_EXEC="$(fx_contract_field "$FX_TMP_ROOT/waitn.out" EXECUTED)"
F_EXEC="$(fx_contract_field "$FX_TMP_ROOT/fifo.out" EXECUTED)"
A_EXEC="$(fx_contract_field "$FX_TMP_ROOT/auto.out" EXECUTED)"

if [ "$W_EXEC" = "6" ] && [ "$F_EXEC" = "6" ] && cmp -s "$FX_TMP_ROOT/waitn.out" "$FX_TMP_ROOT/fifo.out"; then
    fx_pass "E1a. RUN_ALL_REAP=waitn and =fifo produce byte-identical stdout over 6 executed tests"
else
    fx_fail "E1a. waitn/fifo stdout differ or the runs were empty (EXECUTED=$W_EXEC/$F_EXEC)"
    diff "$FX_TMP_ROOT/waitn.out" "$FX_TMP_ROOT/fifo.out" 2>/dev/null | head -n 10 | fx_mask | sed 's/^/    | /'
fi

W_LINE="$(fx_contract_line "$FX_TMP_ROOT/waitn.out")"
F_LINE="$(fx_contract_line "$FX_TMP_ROOT/fifo.out")"
if [ -n "$W_LINE" ] && [ "$W_LINE" = "$F_LINE" ] && [ "$W_EXEC" = "6" ] \
    && [ "${RC_waitn:-x}" = "${RC_fifo:-y}" ] && [ "${RC_waitn:-0}" -eq 1 ]; then
    fx_pass "E1b. both reapers report the same contract and the same exit 1 (one dummy failed)"
else
    fx_fail "E1b. want identical contract lines and exit 1 from both reapers, got exits ${RC_waitn:-?}/${RC_fifo:-?} EXECUTED=$W_EXEC/$F_EXEC"
fi

if [ "$A_EXEC" = "6" ] && cmp -s "$FX_TMP_ROOT/waitn.out" "$FX_TMP_ROOT/auto.out"; then
    fx_pass "E1c. RUN_ALL_REAP=auto resolves to a reaper with identical output"
else
    fx_fail "E1c. RUN_ALL_REAP=auto output differs from the explicit reaper (EXECUTED=$A_EXEC)"
fi

# --- E2/E3: the fallback blocks, it does not poll --------------------------
# Four 2s sleeps at -j 4 finish in about 2s of WALL time while costing almost no
# CPU. A poll loop passes the wall check and fails the CPU check, so the two
# assertions are stated over the same run.
SPIN="$(fx_new_root)"
fx_add_dummy "$SPIN" p1 --sleep 2
fx_add_dummy "$SPIN" p2 --sleep 2
fx_add_dummy "$SPIN" p3 --sleep 2
fx_add_dummy "$SPIN" p4 --sleep 2

CPU0="$(fx_children_user_cs)"
T0="$(fx_now_ms)"
RUN_ALL_REAP=fifo fx_exec "$SPIN" 60 "$FX_TMP_ROOT/spin.out" "$FX_TMP_ROOT/spin.err" -j 4 --all
SPIN_RC=$?
T1="$(fx_now_ms)"
CPU1="$(fx_children_user_cs)"
SPIN_MS=$((T1 - T0))
CPU_CS=$((CPU1 - CPU0))
SPIN_EXEC="$(fx_contract_field "$FX_TMP_ROOT/spin.out" EXECUTED)"

if [ "$SPIN_EXEC" = "4" ] && [ "$SPIN_MS" -lt 6000 ]; then
    fx_pass "E2. fifo reaper at -j 4: four 2s tests finished in ${SPIN_MS}ms (exit $SPIN_RC)"
else
    fx_fail "E2. want EXECUTED=4 within 6000ms at -j 4, got EXECUTED=$SPIN_EXEC in ${SPIN_MS}ms"
fi

if [ "$SPIN_EXEC" = "4" ] && [ "$CPU_CS" -lt 100 ]; then
    fx_pass "E3. the same run cost ${CPU_CS}cs of children user CPU — it blocks rather than polls"
else
    fx_fail "E3. want EXECUTED=4 with under 100cs children user CPU (no busy-wait), got EXECUTED=$SPIN_EXEC using ${CPU_CS}cs"
fi

# --- E4: liveness when many children finish at once, in EVERY reap mode ----

# The `wait -n` job-table hazard: jobs that completed before the parent waited
# can be dropped from the notification, leaving the in-flight set permanently
# non-empty. Eight dummies with the same sleep make them all land together.

# The burst is run under fifo and auto as well, because the symmetric hazard is
# the fallback's own (CPR-ORTH): a FIFO whose writers collide on one burst loses
# notifications exactly the way `wait -n` does, and a fifo-only implementation
# that drops them would still pass a waitn-only case. All three must reap all
# eight children and terminate on the SAME contract and the SAME exit code.

LIVE="$(fx_new_root)"
for i in 1 2 3 4 5 6 7 8; do
    fx_add_dummy "$LIVE" "w$i" --sleep 1 --lines 1
done

E4_LINES=""
E4_RCS=""
for mode in waitn fifo auto; do
    out="$FX_TMP_ROOT/live-$mode.out"
    RUN_ALL_REAP="$mode" fx_exec "$LIVE" 60 "$out" "$FX_TMP_ROOT/live-$mode.err" -j 4 --all
    rc=$?
    l_exec="$(fx_contract_field "$out" EXECUTED)"
    l_pass="$(fx_contract_field "$out" PASS)"
    if [ "$l_exec" = "8" ] && [ "$l_pass" = "8" ] && [ "$rc" -eq 0 ]; then
        fx_pass "E4-$mode. -j 4: 8 simultaneously-finishing tests all reaped, exit 0"
    else
        fx_fail "E4-$mode. want EXECUTED=8 PASS=8 exit 0 within the 60s bound, got EXECUTED=$l_exec PASS=$l_pass exit $rc"
    fi
    E4_LINES="$E4_LINES
$(fx_contract_line "$out")"
    E4_RCS="$E4_RCS $rc"
done

E4_UNIQ_LINES="$(printf '%s\n' "$E4_LINES" | grep -v '^$' | sort -u | wc -l | tr -d ' ')"
E4_UNIQ_RCS="$(printf '%s\n' $E4_RCS | sort -u | wc -l | tr -d ' ')"
E4_REF_EXEC="$(fx_contract_field "$FX_TMP_ROOT/live-waitn.out" EXECUTED)"
if [ "$E4_REF_EXEC" = "8" ] && [ "$E4_UNIQ_LINES" = "1" ] && [ "$E4_UNIQ_RCS" = "1" ]; then
    fx_pass "E4-same. waitn, fifo and auto end the same 8-way burst on one contract line and one exit code"
else
    fx_fail "E4-same. want EXECUTED=8 with 1 distinct contract line and 1 distinct exit code across waitn/fifo/auto, got EXECUTED=$E4_REF_EXEC lines=$E4_UNIQ_LINES exits=$E4_UNIQ_RCS ($E4_RCS)"
fi

# --- E5: `auto` must actually FALL BACK, not merely resolve ----------------

# E1c only proves `auto` lands on a reaper that works on THIS host, where
# `wait -n` exists — so an `auto` hard-wired to waitn passes it. The fallback
# arm is the whole reason the fifo reaper was written, and it is unreachable
# from a test unless the probe is steerable. The seam pinned here is
# RUN_ALL_WAITN_PROBE: `0` = pretend `wait -n` is unavailable, `1` = pretend it
# is available, unset = real detection; consulted ONLY while resolving `auto`.
# The selection is made observable by one stderr line, `[run-all] reap: <mode>`.

reap_line() { sed -n 's/^\[run-all\] reap: \([a-z][a-z-]*\)[[:blank:]]*$/\1/p' "$1" | head -n 1; }
reap_count() { grep -c '^\[run-all\] reap: ' "$1" 2>/dev/null; return 0; }

RUN_ALL_REAP=auto RUN_ALL_WAITN_PROBE=1 \
    fx_exec "$EQ" 90 "$FX_TMP_ROOT/a1.out" "$FX_TMP_ROOT/a1.err" -j 3 --all
A1_RC=$?
RUN_ALL_REAP=auto RUN_ALL_WAITN_PROBE=0 \
    fx_exec "$EQ" 90 "$FX_TMP_ROOT/a0.out" "$FX_TMP_ROOT/a0.err" -j 3 --all
A0_RC=$?
RUN_ALL_REAP=fifo RUN_ALL_WAITN_PROBE=1 \
    fx_exec "$EQ" 90 "$FX_TMP_ROOT/f1.out" "$FX_TMP_ROOT/f1.err" -j 3 --all
F1_RC=$?

A1_EXEC="$(fx_contract_field "$FX_TMP_ROOT/a1.out" EXECUTED)"
A0_EXEC="$(fx_contract_field "$FX_TMP_ROOT/a0.out" EXECUTED)"
F1_EXEC="$(fx_contract_field "$FX_TMP_ROOT/f1.out" EXECUTED)"

if [ "$A1_EXEC" = "6" ] && [ "$(reap_line "$FX_TMP_ROOT/a1.err")" = "waitn" ]; then
    fx_pass "E5a. EXECUTED=6: auto with \`wait -n\` available selects waitn and says so on stderr"
else
    fx_fail "E5a. want EXECUTED=6 and '[run-all] reap: waitn', got EXECUTED=$A1_EXEC reap=[$(reap_line "$FX_TMP_ROOT/a1.err")]"
fi

if [ "$A0_EXEC" = "6" ] && [ "$(reap_line "$FX_TMP_ROOT/a0.err")" = "fifo" ]; then
    fx_pass "E5b. EXECUTED=6: auto with \`wait -n\` unavailable falls back to fifo and says so on stderr"
else
    fx_fail "E5b. want EXECUTED=6 and '[run-all] reap: fifo' under RUN_ALL_WAITN_PROBE=0, got EXECUTED=$A0_EXEC reap=[$(reap_line "$FX_TMP_ROOT/a0.err")]"
fi

A0_LINE="$(fx_contract_line "$FX_TMP_ROOT/a0.out")"
FI_LINE="$(fx_contract_line "$FX_TMP_ROOT/fifo.out")"
if [ "$A0_EXEC" = "6" ] && [ -n "$A0_LINE" ] && [ "$A0_LINE" = "$FI_LINE" ] \
    && [ "$A0_RC" = "${RC_fifo:-x}" ] && cmp -s "$FX_TMP_ROOT/a0.out" "$FX_TMP_ROOT/fifo.out"; then
    fx_pass "E5c. EXECUTED=6: the auto-fallback run matches explicitly-forced fifo on stdout, contract and exit ($A0_RC)"
else
    fx_fail "E5c. want EXECUTED=6 with stdout, contract and exit identical to RUN_ALL_REAP=fifo, got EXECUTED=$A0_EXEC exit $A0_RC vs ${RC_fifo:-?}"
fi

if [ "$F1_EXEC" = "6" ] && [ "$(reap_line "$FX_TMP_ROOT/f1.err")" = "fifo" ] && [ "$F1_RC" = "${RC_fifo:-x}" ]; then
    fx_pass "E5d. EXECUTED=6: an explicit RUN_ALL_REAP=fifo ignores the probe — it is consulted only for auto"
else
    fx_fail "E5d. want EXECUTED=6 and reap fifo under RUN_ALL_REAP=fifo with RUN_ALL_WAITN_PROBE=1, got EXECUTED=$F1_EXEC reap=[$(reap_line "$FX_TMP_ROOT/f1.err")] exit $F1_RC"
fi

R_N1="$(reap_count "$FX_TMP_ROOT/a1.err")"
R_N0="$(reap_count "$FX_TMP_ROOT/a0.err")"
if [ "$A1_EXEC" = "6" ] && [ "$A0_EXEC" = "6" ] && [ "$R_N1" = "1" ] && [ "$R_N0" = "1" ]; then
    fx_pass "E5e. EXECUTED=6 on both runs: the reaper is announced exactly once per run, not once per job"
else
    fx_fail "E5e. want EXECUTED=6 and exactly one '[run-all] reap: ' line per run, got EXECUTED=$A1_EXEC/$A0_EXEC lines=$R_N1/$R_N0 (exit $A1_RC/$A0_RC)"
fi

# The fallback must still be parallel: 6 dummies totalling 9s of sleep finish
# in roughly 4s at -j 3, so a fallback that quietly serialised would not fit.
FB0="$(fx_now_ms)"
RUN_ALL_REAP=auto RUN_ALL_WAITN_PROBE=0 \
    fx_exec "$EQ" 90 "$FX_TMP_ROOT/fbt.out" "$FX_TMP_ROOT/fbt.err" -j 3 --all
FB1="$(fx_now_ms)"
FB_MS=$((FB1 - FB0))
FB_EXEC="$(fx_contract_field "$FX_TMP_ROOT/fbt.out" EXECUTED)"
if [ "$FB_EXEC" = "6" ] && [ "$FB_MS" -lt 7000 ]; then
    fx_pass "E5f. EXECUTED=6: the fifo fallback still ran at -j 3 — 9s of sleep finished in ${FB_MS}ms"
else
    fx_fail "E5f. want EXECUTED=6 within 7000ms at -j 3 on the fallback path, got EXECUTED=$FB_EXEC in ${FB_MS}ms"
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$FX_TMP_ROOT/live-fifo.err" 20

fx_finish
