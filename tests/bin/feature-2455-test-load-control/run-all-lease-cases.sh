#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/run-all-lease-cases.sh — R1-R7.
# The run-all lease: the -j cap, --print-plan, release on every exit path, exit 4, the
# held marker, the heartbeat and --deadline. R8-R13 live in run-all-grant-cases.sh.
# Relies on _runner-fixture.sh.

case_begin "run-all-lease" "tests/run-all.sh"

# ── R1 the lease caps -j at N-1 ─────────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=5; TEST_LANES_WAIT_INTERVAL=1
R1="$(r_root 6 --peak --sleep 1)"
fx_exec "$R1" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R1 run exits 0" "0" "$_rc"
r_has_lanes_line && pass "R1 stderr carries a '[run-all] lanes:' line" || fail "R1 no lanes: line on stderr"
[[ "$(r_lanes_line)" =~ ^jobs\ 2\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 3,\ source\ env\;\ lanes\ 1\ 2\) ]] \
    && pass "R1 lanes: line is 'jobs <granted> of requested <n> (max jobs per host <H>, source <s>; lanes <i...>)'" \
    || fail "R1 lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
assert_eq "R1 N=3, -j 8: peak concurrency is N-1 = 2" "2" "$(fx_peak_of "$(fx_peak_log "$R1")")"
case_ran R1

# ── R2 --print-plan leases nothing; jobs= is min(requested, H-1) ────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3
R2="$(r_root 2)"
fx_exec "$R2" 60 "$R_OUT" "$R_ERR" --print-plan --all; _rc=$?
assert_eq "R2 --print-plan exits 0" "0" "$_rc"
assert_eq "R2 --print-plan creates no lane" "" "$(lane_names "$FX_CACHE_DIR")"
# Eight tests and -j 8 make the requested width 8 whether or not it is clamped to the test count.
R2W="$(r_root 8)"
r2_plan() {  # r2_plan <label> <want-jobs> <want-plan-note-prefix> [want-substring]
    fx_exec "$R2W" 60 "$R_OUT" "$R_ERR" --print-plan -j 8 --all; _rc=$?
    assert_eq "R2 $1: --print-plan exits 0" "0" "$_rc"
    assert_eq "R2 $1: jobs= is $2" "jobs=$2" "$(grep '^jobs=' "$R_OUT")"
    grep -qF -- "plan: $3" "$R_ERR" && pass "R2 $1: stderr carries 'plan: $3'" || fail "R2 $1: stderr lacks 'plan: $3' — err=$(printf '%q' "$(cat "$R_ERR")")"
    if [ -n "${4:-}" ]; then
        grep -F -- "plan: $3" "$R_ERR" | grep -qF -- "$4" && pass "R2 $1: the plan line says '$4'" || fail "R2 $1: the plan line lacks '$4' — err=$(printf '%q' "$(cat "$R_ERR")")"
    fi
    assert_eq "R2 $1: --print-plan creates no lane" "" "$(lane_names "$FX_CACHE_DIR")"
}
r_reset; TEST_MAX_JOBS_PER_HOST=3
# #2687 ③ / #2692: the plan note says the width slow-starts and is re-evaluated, not a fixed lease.
r2_plan "H=3 -j 8" 2 "jobs 2 of requested 8 (max jobs per host 3, source env" \
    "starts at up to 4 and grows per run-all lane allocation sample (slow start); re-evaluated at each entry-script end; running jobs are never stopped, so a run may hold more than its per-run lane cap until they finish"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
r2_plan "TEST_LANES=off" 8 "not applied (TEST_LANES=off); jobs 8 as requested"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HELD=123
r2_plan "nested holder" 8 "not applied (nested under a lane holder); jobs 8 as requested"
case_ran R2

# ── R3 lanes are released on every exit path ────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HEARTBEAT=1
R3="$(r_root 2)"
fx_exec "$R3" 60 "$R_OUT" "$R_ERR" -j 2 --all; _rc=$?
assert_eq "R3 normal exit: rc 0" "0" "$_rc"
r_no_leftover "R3 normal exit"
R3F="$(r_root 1 --exit 1)"
fx_exec "$R3F" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R3 FAIL exit: rc 1" "1" "$_rc"
r_no_leftover "R3 FAIL exit"
R3I="$(r_root 1 --sleep 30)"
fx_exec_bg "$R3I" "$R_OUT" "$R_ERR" --all
if r_wait_file 20 "$R3I/pids/p1.self"; then
    [ -n "$(lane_names "$FX_CACHE_DIR")" ] && pass "R3 INT: a lane is held while the run is in flight (positive control)" || fail "R3 INT: no lane held while the run is in flight"
    kill -INT "$FX_BG_PID" 2>/dev/null || true
    r_wait_gone 20 "$FX_BG_PID" || kill -KILL "$FX_BG_PID" 2>/dev/null
    wait "$FX_BG_PID" 2>/dev/null
    r_no_leftover "R3 INT after the interrupt"
else
    fx_kill_tree "$FX_BG_PID"; wait "$FX_BG_PID" 2>/dev/null
    fail "R3 INT: the run never started its test, interrupt path unverifiable"
fi
for _p in $(fx_recorded_pids "$R3I"); do fx_kill_tree "$_p"; done
# Fixed on purpose: the negative check below needs the heartbeat interval (1 s) to pass twice.
sleep 2
assert_eq "R3 still no lane 2s later (no heartbeat re-created one)" "" "$(lane_names "$FX_CACHE_DIR")"
case_ran R3

# ── R4 full lanes: exit 4 without a contract ────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=2; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R4="$(r_root 1)"
fx_exec "$R4" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R4 lanes 1..N-1 live: run-all exits 4" "4" "$_rc"
grep -q 'RUN_CONTRACT:' "$R_OUT" && fail "R4 stdout carries a RUN_CONTRACT line at exit 4" || pass "R4 no RUN_CONTRACT line at exit 4"
grep -q 'Results:' "$R_OUT" && fail "R4 stdout carries a Results line at exit 4" || pass "R4 no Results line at exit 4"
# Same cause text as the find-tests exit-4 line (L4), emitted once — not per retry or per trap.
assert_eq "R4 stderr names the wait cap exactly once" "1" "$(grep -c 'no test lane freed within' "$R_ERR")"
case_ran R4

# ── R5 children see TEST_LANES_HELD ─────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2
R5="$(r_root 0)"
printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\nprintf "%%s\\n" "${TEST_LANES_HELD-unset}" > "%s/held.txt"\nexit 0\n' "$R5" > "$R5/tests/bin/held.sh"
fx_exec "$R5" 60 "$R_OUT" "$R_ERR" --all
_h="$(cat "$R5/held.txt" 2>/dev/null)"
[[ "$_h" =~ ^[0-9]+$ ]] && pass "R5 child tests inherit TEST_LANES_HELD=<holder pid>" || fail "R5 child saw TEST_LANES_HELD=[$_h]"
case_ran R5

# ── R6 the heartbeat advances during a long test ────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2; TEST_LANES_HEARTBEAT=1
R6="$(r_root 0)"
printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\nf="$RUN_ALL_CACHE_DIR/slots/lane.1/hb"\na="$(cat "$f" 2>/dev/null)"; sleep 3; b="$(cat "$f" 2>/dev/null)"\nprintf "%%s %%s\\n" "$a" "$b" > "%s/hb.txt"\nexit 0\n' "$R6" > "$R6/tests/bin/hb.sh"
fx_exec "$R6" 60 "$R_OUT" "$R_ERR" --all
read -r _a _b < "$R6/hb.txt" 2>/dev/null || { _a=""; _b=""; }
if [[ "$_a" =~ ^[0-9]+$ ]] && [[ "$_b" =~ ^[0-9]+$ ]] && [ "$_b" -gt "$_a" ]; then
    pass "R6 hb advanced during a 3s test ($_a -> $_b)"
else
    fail "R6 hb did not advance (before=[$_a] after=[$_b])"
fi
case_ran R6

# ── R7 --deadline truncates the lane wait ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R7="$(r_root 1)"
_s=$SECONDS
fx_exec "$R7" 60 "$R_OUT" "$R_ERR" --deadline 3 --all; _rc=$?
_el=$((SECONDS - _s))
assert_eq "R7 --deadline 3 with full lanes: exit 4" "4" "$_rc"
if [ "$_rc" -eq 4 ] && [ "$_el" -ge 2 ] && [ "$_el" -le 10 ]; then
    pass "R7 the wait was cut at the deadline (${_el}s)"
else
    fail "R7 wait not bounded by --deadline 3 (rc=$_rc elapsed ${_el}s, want rc 4 after 2..10s)"
fi
case_ran R7

r_reset
case_end

grp_done run-all-lease-cases.sh
