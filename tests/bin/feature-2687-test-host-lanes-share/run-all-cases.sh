#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/run-all-cases.sh — FS8, FS12, FS13, FS16:
# two concurrent run-alls share the pool, exit paths leave nothing, the start-time wait,
# the deadline-bounded mid-run wait. Since #2692 the widths come from the rows the heartbeat
# tick writes (also in mode off), so the cases that need a row run a 1 s heartbeat. FS23: a new
# sample widens or narrows the run while every job still runs.

case_begin "run-all-per-run-cap" "tests/run-all.sh"

# ── FS8 two concurrent run-alls never exceed the pool together, and both progress ─
# B arrives while A holds all 3 lanes, waits at start for a free lane, and starts only once the
# tick shrinks A to 2 and a running A test ends (running tests are never stopped). A's 12 tests
# of 2 s keep it busy for about 10 s after that, so B's first start falls inside A even on a
# loaded host; the 2 s heartbeat gives the tick a 4 s write window there.
r_reset; TEST_MAX_JOBS_PER_HOST=4; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=60; TEST_LANES_WAIT_INTERVAL=1
TEST_LANES_HEARTBEAT=2
FS8_LOG="$FX_TMP_ROOT/fs8.log"; rm -f "$FS8_LOG"
FS8A="$(fs_root 12 a "$FS8_LOG" 2)"
FS8B="$(fs_root 6 b "$FS8_LOG" 2)"
FS8A_ERR="$FX_TMP_ROOT/fs8a.err"; FS8B_ERR="$FX_TMP_ROOT/fs8b.err"
fx_exec_bg "$FS8A" "$FX_TMP_ROOT/fs8a.out" "$FS8A_ERR" -j 12 --all; FS8_PA="$FX_BG_PID"
fx_wait_file 20 "$FS8A/pids/a3.self"
fx_exec_bg "$FS8B" "$FX_TMP_ROOT/fs8b.out" "$FS8B_ERR" -j 6 --all; FS8_PB="$FX_BG_PID"
fx_wait_gone 90 "$FS8_PA" "$FS8_PB" || { fx_kill_tree "$FS8_PA"; fx_kill_tree "$FS8_PB"; }
wait "$FS8_PA"; _ra=$?
wait "$FS8_PB"; _rb=$?
assert_eq "FS8 run A exits 0" "0" "$_ra"
assert_eq "FS8 run B exits 0" "0" "$_rb"
assert_eq "FS8 all 18 tests started" "18" "$(fx_peak_starts "$FS8_LOG")"
_pk="$(log_peak "$FS8_LOG")"
[ "$_pk" -le 3 ] && pass "FS8 the two runs together stay within pool 3 (peak $_pk)" \
    || fail "FS8 combined peak $_pk exceeds the pool 3"
assert_eq "FS8 the runs overlap (the later run gets its per-run lane cap, not the leftovers)" "1" "$(log_overlap "$FS8_LOG" a b)"
_wl="$(grep -nF "[lanes] waiting for a free lane (2 runs share 3 lanes)" "$FS8B_ERR" | head -n 1)"; _wl="${_wl%%:*}"
_sl="$(grep -nF "lanes: jobs " "$FS8B_ERR" | head -n 1)"; _sl="${_sl%%:*}"
[ -n "$_wl" ] && [ -n "$_sl" ] && [ "$_wl" -lt "$_sl" ] \
    && pass "FS8 (a) run B waits at width 0 for a free lane before its start note" \
    || fail "FS8 (a) no '[lanes] waiting for a free lane (2 runs share 3 lanes)' line before B's 'lanes: jobs' note" "err=$(printf '%q' "$(cat "$FS8B_ERR")")"
grep -qF "lanes: width 3 -> 2 (per-run lane cap 2 among 2 runs, decided by per-run-cap)" "$FS8A_ERR" \
    && pass "FS8 (b) run A shrinks 3 -> 2 by the per-run lane cap once B appears" \
    || fail "FS8 (b) no 'lanes: width 3 -> 2 (per-run lane cap 2 among 2 runs, decided by per-run-cap)' line" "err=$(printf '%q' "$(cat "$FS8A_ERR")")"
read -r _amax _bin <<< "$(log_order "$FS8_LOG" a b)"
assert_eq "FS8 (c) B's first test starts before A's last test ends (B starts inside A)" "1" "$_bin"
[ "$_amax" -le 2 ] && pass "FS8 (c) while B runs, A keeps at most 2 tests inside (max $_amax)" \
    || fail "FS8 (c) A had $_amax tests inside while B ran (the shrink to 2 did not hold)" "log=$(printf '%q' "$(cat "$FS8_LOG")")"
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
# Slow start from 4: the mode-off heartbeat tick writes the rows, and the run reaches 11 alone.
if wait_grep 30 "$FS12_ERR" "-> 11 (per-run lane cap 11 among 1 runs"; then
    pass "FS12 the run grows by slow start to 11 once the earlier run leaves"
    _n="$(now_epoch)"
    FS12_LATE="$LIVE_SLEEP.$((_n + 100)).1202"
    mk_presence "$FX_CACHE_DIR" "$FS12_LATE" "$LIVE_SLEEP" "$((_n + 100))" 12 1000
    wait_grep 20 "$FS12_ERR" "lanes: width 11 -> 6 (per-run lane cap 6 among 2 runs, decided by per-run-cap)" \
        && pass "FS12 the run shrinks 11 -> 6 at once when a later run appears" \
        || fail "FS12 no 'lanes: width 11 -> 6 (per-run lane cap 6 among 2 runs, decided by per-run-cap)' line" "err=$(printf '%q' "$(cat "$FS12_ERR")")"
else
    fail "FS12 no '-> 11 (per-run lane cap 11 among 1 runs' line within 30s (not implemented?)" "err=$(printf '%q' "$(cat "$FS12_ERR")")"
    FS12_LATE=""
fi
grep -qF "lanes: width 4 -> " "$FS12_ERR" && pass "FS12 the first growth starts from the start width 4" \
    || fail "FS12 no 'lanes: width 4 -> ' line (the run did not start at 4)" "err=$(printf '%q' "$(cat "$FS12_ERR")")"
kill -INT "$FS12_P" 2>/dev/null
bg_stop "$FS12_P" "$FS12R"
assert_eq "FS12 INT: no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
assert_eq "FS12 INT: only the fake later record is left" "${FS12_LATE:+run.$FS12_LATE}" "$(run_names "$FX_CACHE_DIR")"
r_reset; TEST_MAX_JOBS_PER_HOST=12; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1; TEST_LANES_HEARTBEAT=1
FS12N="$(fs_root 24 d "$FX_TMP_ROOT/fs12n.log" 1)"
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
grep -qE "lanes: width 4 -> ([5-9]|1[01]) " "$FX_TMP_ROOT/fs12n.err" && pass "FS12 normal end: the run grew from 4 on the way" \
    || fail "FS12 normal end: no 'lanes: width 4 -> <5..11>' growth line" "err=$(printf '%q' "$(cat "$FX_TMP_ROOT/fs12n.err")")"
case_ran FS12

# ── FS13 the start-time per-run-cap-0 wait ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1
# The waiting run follows its own row 0 and gets a width only at the next sample, so the
# heartbeat must be well under the wait cap.
TEST_LANES_HEARTBEAT=1
FS13R="$(fs_root 1 e "$FX_TMP_ROOT/fs13.log" 0)"
_n="$(now_epoch)"
FS13_EARLY="$LIVE_SLEEP.$((_n - 100)).1301"
mk_presence "$FX_CACHE_DIR" "$FS13_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
mk_slot "$FX_CACHE_DIR" 1 "$LIVE_SLEEP" "$FS13_EARLY"
FS13_ERR="$FX_TMP_ROOT/fs13.err"
fx_exec_bg "$FS13R" "$FX_TMP_ROOT/fs13.out" "$FS13_ERR" --all; FS13_P="$FX_BG_PID"
if wait_grep 10 "$FS13_ERR" "[lanes] waiting"; then
    pass "FS13 pool 1 held by an earlier run (headroom 0): the later run prints the waiting line"
    [ -e "$FS13R/pids/e1.self" ] && fail "FS13 a test started while the start width was 0" || pass "FS13 no test starts while waiting"
else
    fail "FS13 no '[lanes] waiting' line within 10s" "err=$(printf '%q' "$(cat "$FS13_ERR")")"
fi
rm -rf "$FX_CACHE_DIR/runs/run.$FS13_EARLY" "$FX_CACHE_DIR/slots/lane.1"
fx_wait_gone 30 "$FS13_P" || fx_kill_tree "$FS13_P"
wait "$FS13_P"; _rc=$?
assert_eq "FS13 the earlier run leaves: the waiting run proceeds and exits 0" "0" "$_rc"
assert_eq "FS13 its test ran" "1" "$(fx_peak_starts "$FX_TMP_ROOT/fs13.log")"
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=3; TEST_LANES_WAIT_INTERVAL=1
_n="$(now_epoch)"
mk_presence "$FX_CACHE_DIR" "$FS13_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
mk_slot "$FX_CACHE_DIR" 1 "$LIVE_SLEEP" "$FS13_EARLY"
fx_exec "$FS13R" 60 "$FX_TMP_ROOT/fs13c.out" "$FX_TMP_ROOT/fs13c.err" --all; _rc=$?
assert_eq "FS13 the earlier run stays: exit 4 at the wait cap" "4" "$_rc"
assert_eq "FS13 exit 4 leaves only the earlier record" "run.$FS13_EARLY" "$(run_names "$FX_CACHE_DIR")"
assert_eq "FS13 exit 4 leaves only the earlier run's lane" "lane.1" "$(lane_names "$FX_CACHE_DIR")"
case_ran FS13

# ── FS16 the mid-run per-run-cap-0 wait obeys --deadline (exit 3, nothing left) ─
r_reset; TEST_MAX_JOBS_PER_HOST=2; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1
# The heartbeat tick (mode off) writes the own row 0 once the earlier record appears.
TEST_LANES_HEARTBEAT=1
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
grep -qF "per-run lane cap 0 among 2 runs" "$FS16_ERR" && pass "FS16 the run reached the per-run-cap-0 dispatch wait" \
    || fail "FS16 no 'per-run lane cap 0 among 2 runs' line (the deadline hit elsewhere?)" "err=$(printf '%q' "$(cat "$FS16_ERR")")"
grep -qF "deadline of 8s exceeded" "$FS16_ERR" && pass "FS16 stderr names the exceeded deadline" \
    || fail "FS16 no 'deadline of 8s exceeded' line" "err=$(printf '%q' "$(cat "$FS16_ERR")")"
[ -e "$FS16R/pids/g2.self" ] && fail "FS16 the second test started while the per-run lane cap was 0" \
    || pass "FS16 no test starts during the bounded wait"
assert_eq "FS16 exit 3 leaves only the earlier record" "run.$FS16_EARLY" "$(run_names "$FX_CACHE_DIR")"
assert_eq "FS16 exit 3 leaves no lane" "" "$(lane_names "$FX_CACHE_DIR")"
case_ran FS16

r_reset
case_end

case_begin "run-all-rebalance-on-sample" "tests/run-all.sh"

# ── FS23 a new sample re-evaluates the width while every job still runs ─────
# A pre-written pool-1 sample without an own row starts the run at width 1; heartbeat 30 and a
# held load/.claim keep the run's own tick off the samples this case writes. Tests h1-h3 sleep
# 10 s, h4 1 s. Both reap paths of reap_wait run (RUN_ALL_REAP=waitn and fifo).
fs23_pass() {
    local m="$1" log="$FX_TMP_ROOT/fs23-$1.log" err="$FX_TMP_ROOT/fs23-$1.err" root p tok at grown=0 rc in4
    r_reset; TEST_MAX_JOBS_PER_HOST=12; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=30; TEST_LANES_WAIT_INTERVAL=1; TEST_LANES_HEARTBEAT=30
    RUN_ALL_REAP="$m"; rm -f "$log"
    root="$(fs_root 3 h "$log" 10)"; fs_dummy "$root" h4 h "$log" 1
    ls2_write "$FX_CACHE_DIR" 0 pool=1
    hold_claim "$FX_CACHE_DIR"
    fx_exec_bg "$root" "$FX_TMP_ROOT/fs23-$m.out" "$err" -j 4 --all; p="$FX_BG_PID"
    if fx_wait_file 20 "$root/pids/h1.self"; then
        grep -qF "reap: $m" "$err" && grep -qF "lanes: jobs 1 of requested 4" "$err" && pass "FS23 [$m] setup: reap $m, the run starts at width 1" \
            || fail "FS23 [$m] setup: not reap $m at width 1" "err=$(printf '%q' "$(cat "$err")")"
        sleep 1
        grep -qF "lanes: width" "$err" && fail "FS23 [$m] control: a width line appeared without a new sample" "err=$(printf '%q' "$(cat "$err")")" \
            || pass "FS23 [$m] control: without a new sample no width line appears before a job ends"
        [ -e "$root/pids/h2.self" ] && fail "FS23 [$m] control: a second test started without a new sample" \
            || pass "FS23 [$m] control: without a new sample no second test starts"
        tok="$(run_names "$FX_CACHE_DIR")"; tok="${tok#run.}"
        ls2_write "$FX_CACHE_DIR" 0 pool=3 -- "$tok=3 15 3 per-run-cap"; at="$(ls2_key "$FX_CACHE_DIR" measured_at)"
        if wait_grep 6 "$err" "[run-all] lanes: width 1 -> 3"; then
            pass "FS23 [$m] a new sample with row 3 widens the run 1 -> 3 while its first test still runs"
            grown=1
            fx_wait_file 5 "$root/pids/h3.self"
            while [ "$(now_epoch)" -le "$at" ]; do sleep 0.2; done
            ls2_write "$FX_CACHE_DIR" 0 pool=1 -- "$tok=1 15 1 per-run-cap"
            wait_grep 5 "$err" "[run-all] lanes: width 3 -> 1" \
                && pass "FS23 [$m] a later sample with row 1 narrows the run 3 -> 1 while 3 tests run" \
                || fail "FS23 [$m] no '[run-all] lanes: width 3 -> 1' line within 5s of the row-1 sample (not implemented yet)" "err=$(printf '%q' "$(cat "$err")")"
        else
            fail "FS23 [$m] no '[run-all] lanes: width 1 -> 3' line within 6s of a new sample while every job runs (not implemented yet)" "err=$(printf '%q' "$(cat "$err")")"
        fi
    else
        fail "FS23 [$m] setup: the first test never started" "err=$(printf '%q' "$(cat "$err")")"
    fi
    if [ "$grown" = 1 ]; then
        fx_wait_gone 40 "$p" || fx_kill_tree "$p"
        wait "$p"; rc=$?
        assert_eq "FS23 [$m] no running test is stopped: the run exits 0" "0" "$rc"
        assert_eq "FS23 [$m] all 4 tests ran to their end" "4" "$(grep -c '^-h ' "$log" 2>/dev/null)"
        assert_eq "FS23 [$m] the 2nd and 3rd tests start before the first one ends" "3" \
            "$(awk '$1 == "-h" { exit } $1 == "+h" { n++ } END { print n + 0 }' "$log")"
        # Width 1 after the shrink: the 4th test starts only once all 3 earlier tests have ended.
        in4="$(awk '$1 == "+h" { s++; if (s == 4) { print n; f = 1; exit } n++ } $1 == "-h" { n-- } END { if (!f) print "none" }' "$log")"
        assert_eq "FS23 [$m] the 4th test starts with 0 tests in flight (width 1)" "0" "$in4"
    else
        kill -INT "$p" 2>/dev/null
    fi
    bg_stop "$p" "$root"
    assert_eq "FS23 [$m] no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
}
fs23_pass waitn
fs23_pass fifo
unset RUN_ALL_REAP
case_ran FS23

r_reset
case_end

grp_done run-all-cases.sh
