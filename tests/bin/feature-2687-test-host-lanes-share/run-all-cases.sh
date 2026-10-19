#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/run-all-cases.sh — FS8, FS12, FS13, FS16:
# two concurrent run-alls share the pool, exit paths leave nothing, the start-time wait,
# the deadline-bounded mid-run wait.

case_begin "run-all-fair-share" "tests/run-all.sh"

# ── FS8 two concurrent run-alls never exceed the pool together, and both progress ─
r_reset; TEST_MAX_JOBS_PER_HOST=4; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=60; TEST_LANES_WAIT_INTERVAL=1
FS8_LOG="$FX_TMP_ROOT/fs8.log"; rm -f "$FS8_LOG"
FS8A="$(fs_root 6 a "$FS8_LOG" 2)"
FS8B="$(fs_root 6 b "$FS8_LOG" 2)"
fx_exec_bg "$FS8A" "$FX_TMP_ROOT/fs8a.out" "$FX_TMP_ROOT/fs8a.err" -j 6 --all; FS8_PA="$FX_BG_PID"
fx_wait_file 20 "$FS8A/pids/a1.self"
fx_exec_bg "$FS8B" "$FX_TMP_ROOT/fs8b.out" "$FX_TMP_ROOT/fs8b.err" -j 6 --all; FS8_PB="$FX_BG_PID"
fx_wait_gone 90 "$FS8_PA" "$FS8_PB" || { fx_kill_tree "$FS8_PA"; fx_kill_tree "$FS8_PB"; }
wait "$FS8_PA"; _ra=$?
wait "$FS8_PB"; _rb=$?
assert_eq "FS8 run A exits 0" "0" "$_ra"
assert_eq "FS8 run B exits 0" "0" "$_rb"
assert_eq "FS8 all 12 tests started" "12" "$(fx_peak_starts "$FS8_LOG")"
_pk="$(log_peak "$FS8_LOG")"
[ "$_pk" -le 3 ] && pass "FS8 the two runs together stay within pool 3 (peak $_pk)" \
    || fail "FS8 combined peak $_pk exceeds the pool 3"
assert_eq "FS8 the runs overlap (the later run gets its fair share, not the leftovers)" "1" "$(log_overlap "$FS8_LOG" a b)"
assert_eq "FS8 no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
assert_eq "FS8 no presence record left" "" "$(run_names "$FX_CACHE_DIR")"
case_ran FS8

case_end

case_begin "run-all-exit-paths" "tests/run-all.sh"

# ── FS12 grow -> shrink, then INT; and a normal end: nothing of the run is left ─
r_reset; TEST_MAX_JOBS_PER_HOST=12; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1; TEST_LANES_HEARTBEAT=1
FS12_LOG="$FX_TMP_ROOT/fs12.log"; rm -f "$FS12_LOG"
FS12R="$(fs_root 40 c "$FS12_LOG" 2)"
_n="$(now_epoch)"
FS12_EARLY="$LIVE_SLEEP.$((_n - 100)).1201"
mk_presence "$FX_CACHE_DIR" "$FS12_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 12 1000
FS12_ERR="$FX_TMP_ROOT/fs12.err"
fx_exec_bg "$FS12R" "$FX_TMP_ROOT/fs12.out" "$FS12_ERR" -j 11 --all; FS12_P="$FX_BG_PID"
fx_wait_file 20 "$FS12R/pids/c1.self"
rm -rf "$FX_CACHE_DIR/runs/run.$FS12_EARLY"
if wait_grep 20 "$FS12_ERR" "lanes: width 5 -> 11"; then
    pass "FS12 the run grows 5 -> 11 when the earlier run leaves"
    _n="$(now_epoch)"
    FS12_LATE="$LIVE_SLEEP.$((_n + 100)).1202"
    mk_presence "$FX_CACHE_DIR" "$FS12_LATE" "$LIVE_SLEEP" "$((_n + 100))" 12 1000
    wait_grep 20 "$FS12_ERR" "lanes: width 11 -> 6" && pass "FS12 the run shrinks 11 -> 6 when a later run appears" \
        || fail "FS12 no 'lanes: width 11 -> 6' line" "err=$(printf '%q' "$(cat "$FS12_ERR")")"
else
    fail "FS12 no 'lanes: width 5 -> 11' line within 20s (not implemented?)" "err=$(printf '%q' "$(cat "$FS12_ERR")")"
    FS12_LATE=""
fi
kill -INT "$FS12_P" 2>/dev/null
bg_stop "$FS12_P" "$FS12R"
assert_eq "FS12 INT: no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
assert_eq "FS12 INT: only the fake later record is left" "${FS12_LATE:+run.$FS12_LATE}" "$(run_names "$FX_CACHE_DIR")"
r_reset; TEST_MAX_JOBS_PER_HOST=12; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1
FS12N="$(fs_root 12 d "$FX_TMP_ROOT/fs12n.log" 1)"
_n="$(now_epoch)"
FS12N_EARLY="$LIVE_SLEEP.$((_n - 100)).1203"
mk_presence "$FX_CACHE_DIR" "$FS12N_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 12 1000
fx_exec_bg "$FS12N" "$FX_TMP_ROOT/fs12n.out" "$FX_TMP_ROOT/fs12n.err" -j 11 --all; FS12N_P="$FX_BG_PID"
fx_wait_file 20 "$FS12N/pids/d1.self"
rm -rf "$FX_CACHE_DIR/runs/run.$FS12N_EARLY"
fx_wait_gone 60 "$FS12N_P" || fx_kill_tree "$FS12N_P"
wait "$FS12N_P"; _rc=$?
assert_eq "FS12 normal end: rc 0" "0" "$_rc"
assert_eq "FS12 normal end: no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
assert_eq "FS12 normal end: no presence record left" "" "$(run_names "$FX_CACHE_DIR")"
grep -qF "lanes: width 5 -> 11" "$FX_TMP_ROOT/fs12n.err" && pass "FS12 normal end: the run grew on the way" \
    || fail "FS12 normal end: no growth line" "err=$(printf '%q' "$(cat "$FX_TMP_ROOT/fs12n.err")")"
case_ran FS12

# ── FS13 the start-time fair-share-0 wait ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1
FS13R="$(fs_root 1 e "$FX_TMP_ROOT/fs13.log" 0)"
_n="$(now_epoch)"
FS13_EARLY="$LIVE_SLEEP.$((_n - 100)).1301"
mk_presence "$FX_CACHE_DIR" "$FS13_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
FS13_ERR="$FX_TMP_ROOT/fs13.err"
fx_exec_bg "$FS13R" "$FX_TMP_ROOT/fs13.out" "$FS13_ERR" --all; FS13_P="$FX_BG_PID"
if wait_grep 10 "$FS13_ERR" "[lanes] waiting for a fair share (1 runs ahead share 1 lanes)"; then
    pass "FS13 pool 1 held by an earlier run: the later run prints the waiting line"
    [ -e "$FS13R/pids/e1.self" ] && fail "FS13 a test started while the fair share was 0" || pass "FS13 no test starts while waiting"
else
    fail "FS13 no fair-share waiting line within 10s (not implemented?)" "err=$(printf '%q' "$(cat "$FS13_ERR")")"
fi
rm -rf "$FX_CACHE_DIR/runs/run.$FS13_EARLY"
fx_wait_gone 30 "$FS13_P" || fx_kill_tree "$FS13_P"
wait "$FS13_P"; _rc=$?
assert_eq "FS13 the earlier run leaves: the waiting run proceeds and exits 0" "0" "$_rc"
assert_eq "FS13 its test ran" "1" "$(fx_peak_starts "$FX_TMP_ROOT/fs13.log")"
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=3; TEST_LANES_WAIT_INTERVAL=1
_n="$(now_epoch)"
mk_presence "$FX_CACHE_DIR" "$FS13_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
fx_exec "$FS13R" 60 "$FX_TMP_ROOT/fs13c.out" "$FX_TMP_ROOT/fs13c.err" --all; _rc=$?
assert_eq "FS13 the earlier run stays: exit 4 at the wait cap" "4" "$_rc"
assert_eq "FS13 exit 4 leaves only the earlier record" "run.$FS13_EARLY" "$(run_names "$FX_CACHE_DIR")"
assert_eq "FS13 exit 4 leaves no lane" "" "$(lane_names "$FX_CACHE_DIR")"
case_ran FS13

# ── FS16 the mid-run fair-share-0 wait obeys --deadline (exit 3, nothing left) ─
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1
FS16R="$(fs_root 2 g "$FX_TMP_ROOT/fs16.log" 3)"
FS16_ERR="$FX_TMP_ROOT/fs16.err"
fx_exec_bg "$FS16R" "$FX_TMP_ROOT/fs16.out" "$FS16_ERR" --all --deadline 8; FS16_P="$FX_BG_PID"
fx_wait_file 20 "$FS16R/pids/g1.self"
_n="$(now_epoch)"
FS16_EARLY="$LIVE_SLEEP.$((_n - 100)).1602"
mk_presence "$FX_CACHE_DIR" "$FS16_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
fx_wait_gone 30 "$FS16_P" || fx_kill_tree "$FS16_P"
wait "$FS16_P"; _rc=$?
bg_stop "$FS16_P" "$FS16R"
assert_eq "FS16 an earlier run takes pool 1 mid-run: the deadline ends the wait with exit 3" "3" "$_rc"
grep -qF "fair share 0 among 2 runs" "$FS16_ERR" && pass "FS16 the run reached the fair-share-0 dispatch wait" \
    || fail "FS16 no 'fair share 0 among 2 runs' line (the deadline hit elsewhere?)" "err=$(printf '%q' "$(cat "$FS16_ERR")")"
grep -qF "deadline of 8s exceeded" "$FS16_ERR" && pass "FS16 stderr names the exceeded deadline" \
    || fail "FS16 no 'deadline of 8s exceeded' line" "err=$(printf '%q' "$(cat "$FS16_ERR")")"
[ -e "$FS16R/pids/g2.self" ] && fail "FS16 the second test started while the fair share was 0" \
    || pass "FS16 no test starts during the bounded wait"
assert_eq "FS16 exit 3 leaves only the earlier record" "run.$FS16_EARLY" "$(run_names "$FX_CACHE_DIR")"
assert_eq "FS16 exit 3 leaves no lane" "" "$(lane_names "$FX_CACHE_DIR")"
case_ran FS16

r_reset
case_end

grp_done run-all-cases.sh
