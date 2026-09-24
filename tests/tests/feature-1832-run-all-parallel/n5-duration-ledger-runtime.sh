#!/usr/bin/env bash
# n5-duration-ledger-runtime.sh — the ledger observed through real child processes.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: n2- proves the PLAN re-orders and n- proves records exist, but neither watches a real
# subprocess. These cases observe the runner from outside its own reporting: which child
# actually started first, which verdicts record, whose clock, and what a killed child leaves.

# TL3 gap (what this test does NOT catch):
# - a loaded host where 1s SECONDS granularity moves a dummy across a tier boundary
# - a real corpus where the LPT win is minutes rather than a 3-dummy fixture
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n5-duration-ledger-runtime"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"

# Every ledger row names the absent implementation instead of crashing (RED-FIRST).
dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

# secs_of_key <substring> — seconds of the last record whose key contains that substring.
secs_of_key() {
    fx_ledger_cat | awk -F'|' -v pat="$1" 'NF == 3 && index($3, pat) { v = $2 } END { print v }'
}

# keys_matching <substring> — how many records carry a key containing that substring.
keys_matching() {
    fx_ledger_cat | awk -F'|' -v pat="$1" 'NF == 3 && index($3, pat) { n++ } END { print n + 0 }'
}

# ===========================================================================
# N22 — the SUBPROCESSES start in LPT order, not just the printed plan
# ===========================================================================
# At -j 1 exactly one child is alive at a time, so the shared start/end log IS the
# execution order. --print-plan is never consulted here: this is independent evidence.
Q="$(fx_new_root)"
fx_add_dummy "$Q" q1 --sleep 2 --log
fx_add_dummy "$Q" q2 --sleep 8 --log
fx_add_dummy "$Q" q3 --sleep 4 --log

QW_OUT="$FX_TMP_ROOT/qw.out"; QW_ERR="$FX_TMP_ROOT/qw.err"
QS_OUT="$FX_TMP_ROOT/qs.out"; QS_ERR="$FX_TMP_ROOT/qs.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$Q" 120 "$QW_OUT" "$QW_ERR" -j 3 --all
QW_EXEC="$(fx_contract_field "$QW_OUT" EXECUTED)"

: > "$(fx_log "$Q")"
fx_exec "$Q" 150 "$QS_OUT" "$QS_ERR" -j 1 --all
QS_EXEC="$(fx_contract_field "$QS_OUT" EXECUTED)"
FX_LEDGER_KEEP=0

Q_SEQ="$(awk '{ printf "%s:%s ", $1, $2 }' "$(fx_log "$Q")" 2>/dev/null || true)"
Q_STARTS="$(grep -c '^start ' "$(fx_log "$Q")" 2>/dev/null || true)"

if [ "$QW_EXEC" = "3" ] && [ "$QS_EXEC" = "3" ] && [ "$Q_STARTS" = "3" ]; then
    fx_pass "N22b. the fixture is real: the warm-up and the -j 1 run each executed 3 dummies, 3 children started"
else
    fx_fail "N22b. the fixture is not usable — want EXECUTED=3 twice and 3 start lines, got warm=${QW_EXEC:-absent} serial=${QS_EXEC:-absent} starts=$Q_STARTS"
    fx_show_tail "$QS_ERR" 6
fi

# The interleaved start:/end: pairs also assert the lane really was serial, so
# "started first" is unambiguous rather than an artefact of overlapping children.
if dur_missing "N22. at -j 1 the children START in longest-first order"; then :
elif [ "$Q_SEQ" = "start:q2 end:q2 start:q3 end:q3 start:q1 end:q1 " ]; then
    fx_pass "N22. the observed child sequence was q2 (8s), then q3 (4s), then q1 (2s)"
else
    fx_fail "N22. want the child log 'start:q2 end:q2 start:q3 end:q3 start:q1 end:q1 ', got '$Q_SEQ'"
fi

# ===========================================================================
# N23 — one record per COMPLETED test, whatever the verdict
# ===========================================================================
# A writer hung off the PASS branch would leave this run with one record instead of three.
P="$(fx_new_root)"
fx_add_dummy "$P" p1 --exit 0
fx_add_dummy "$P" p2 --exit 1
fx_add_dummy "$P" p3 --exit 77

P_OUT="$FX_TMP_ROOT/p.out"; P_ERR="$FX_TMP_ROOT/p.err"
fx_exec "$P" 90 "$P_OUT" "$P_ERR" -j 3 --all
P_PASS="$(fx_contract_field "$P_OUT" PASS)"
P_FAIL="$(fx_contract_field "$P_OUT" FAIL)"
P_SKIP="$(fx_contract_field "$P_OUT" SKIP)"
P_EXEC="$(fx_contract_field "$P_OUT" EXECUTED)"
P_LINES="$(fx_ledger_lines)"
P_ONCE="$(fx_ledger_cat | awk -F'|' 'NF == 3 { n[$3]++ } END { c = 0; for (k in n) if (n[k] == 1) c++; print c + 0 }')"
P1_N="$(keys_matching p1.sh)"; P2_N="$(keys_matching p2.sh)"; P3_N="$(keys_matching p3.sh)"

if [ "$P_PASS" = "1" ] && [ "$P_FAIL" = "1" ] && [ "$P_SKIP" = "1" ] && [ "$P_EXEC" = "3" ]; then
    fx_pass "N23b. the fixture is real: the run produced one PASS, one FAIL and one SKIP"
else
    fx_fail "N23b. the fixture is not usable — want PASS=1 FAIL=1 SKIP=1 EXECUTED=3, got PASS=${P_PASS:-absent} FAIL=${P_FAIL:-absent} SKIP=${P_SKIP:-absent} EXECUTED=${P_EXEC:-absent}"
    fx_show_tail "$P_ERR" 6
fi

if dur_missing "N23. a PASS/FAIL/SKIP mix writes exactly one record per test"; then :
elif [ "$P_EXEC" = "3" ] && [ "$P_LINES" = "3" ] && [ "$P_ONCE" = "3" ] && \
     [ "$P1_N" = "1" ] && [ "$P2_N" = "1" ] && [ "$P3_N" = "1" ]; then
    fx_pass "N23. the passing, failing and skipping dummies each left exactly one record (3 lines, 3 keys)"
else
    fx_fail "N23. want 3 records with p1/p2/p3 each exactly once, got lines=$P_LINES seen-once=$P_ONCE p1=$P1_N p2=$P2_N p3=$P3_N"
fi

# ===========================================================================
# N24 — the seconds come from the child, not from the moment the parent reaped it
# ===========================================================================
# RUN_ALL_REAP=fifo waits on the FIRST in-flight job, so the 1s dummy is not harvested
# until the 8s one ends. A parent-side stopwatch would therefore record ~8s for BOTH.
R="$(fx_new_root)"
fx_add_dummy "$R" r1 --sleep 8
fx_add_dummy "$R" r2 --sleep 1

R_OUT="$FX_TMP_ROOT/r.out"; R_ERR="$FX_TMP_ROOT/r.err"
RUN_ALL_REAP=fifo
fx_exec "$R" 120 "$R_OUT" "$R_ERR" -j 2 --all
unset RUN_ALL_REAP
R_EXEC="$(fx_contract_field "$R_OUT" EXECUTED)"
R_LINES="$(fx_ledger_lines)"
R1_SECS="$(secs_of_key r1.sh)"
R2_SECS="$(secs_of_key r2.sh)"

if [ "$R_EXEC" = "2" ]; then
    fx_pass "N24b. the fixture is real: both dummies ran under RUN_ALL_REAP=fifo"
else
    fx_fail "N24b. the fixture is not usable — want EXECUTED=2 under fifo reaping, got ${R_EXEC:-absent}"
    fx_show_tail "$R_ERR" 6
fi

if dur_missing "N24. durations are measured child-side, not at parent harvest time"; then :
elif [ "$R_LINES" = "2" ] && [ "${R2_SECS:-x}" -le 3 ] 2>/dev/null && \
     [ "${R1_SECS:-x}" -ge 6 ] 2>/dev/null; then
    fx_pass "N24. deferred reaping still recorded r2 as ${R2_SECS}s and r1 as ${R1_SECS}s — the child's own clock"
else
    fx_fail "N24. want 2 records with r2<=3s and r1>=6s, got lines=$R_LINES r1='${R1_SECS:-absent}' r2='${R2_SECS:-absent}' — r2 near r1 means the parent's harvest clock was used"
fi

# ===========================================================================
# N25 — a child killed at the deadline leaves no record; one that beat it keeps its own
# ===========================================================================
# Recording a killed child would store a truncated duration that then pulls the test
# EARLIER in every later run — the exact opposite of what LPT ordering wants.
K="$(fx_new_root)"
fx_add_dummy "$K" k1 --sleep 1
fx_add_dummy "$K" k2 --sleep 30

K_OUT="$FX_TMP_ROOT/k.out"; K_ERR="$FX_TMP_ROOT/k.err"
fx_exec "$K" 90 "$K_OUT" "$K_ERR" --deadline 5 -j 2 --all
K_RC=$?
K_SEGS="$(fx_ledger_segments)"
K_LINES="$(fx_ledger_lines)"
K_K1="$(keys_matching k1.sh)"
K_K2="$(keys_matching k2.sh)"

if [ "$K_RC" -eq 3 ]; then
    fx_pass "N25b. the fixture is real: the 30s dummy tripped the 5s deadline (exit 3)"
else
    fx_fail "N25b. the fixture is not usable — want exit 3 from the deadline abort, got $K_RC"
    fx_show_tail "$K_ERR" 6
fi

if dur_missing "N25. only the child that finished before the deadline is recorded"; then :
elif [ "$K_RC" -eq 3 ] && [ "$K_SEGS" = "1" ] && [ "$K_LINES" = "1" ] && \
     [ "$K_K1" = "1" ] && [ "$K_K2" = "0" ]; then
    fx_pass "N25. the deadline run kept k1's record and wrote nothing for the killed k2"
else
    fx_fail "N25. want exit 3, 1 segment, 1 record, k1 once and k2 never, got exit $K_RC segments=$K_SEGS lines=$K_LINES k1=$K_K1 k2=$K_K2"
fi

fx_finish
