#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/share-cases.sh — FS1-FS4, FS15:
# the fair-share computation, the pool from presence records, reclaim, and the start-time wait.
# Self-position is 0-based in start order; an unbounded demand is written as 1000.

case_begin "fair-share-compute" "bin/lib/test-host-lanes-share.sh"

# ── FS1 the water-fill table; every row sums to at most the pool ────────────
lanes_drv "$(new_cache)" -- '
fs_row 11 1000
fs_row 11 1000 1000
fs_row 11 1000 1000 1000
fs_row 11 2 1000
fs_row 11 2 1000 1000
fs_row 3 1000 1000 1000 1000 1000
fs_row 1 1000 1000 1000
fs_row 11 3'
assert_eq "FS1 driver loads the share lib (rc 0)" "0" "$RC"
FS1_ROWS=()
while IFS= read -r _l; do FS1_ROWS+=("$_l"); done <<<"$OUT"
fs1_row() {  # fs1_row <index> <label> <want> <pool>
    local got="${FS1_ROWS[$1]:-}"
    assert_eq "FS1 $2" "$3" "$got"
    if [ -n "$got" ] && [ "$(row_sum "$got")" -le "$4" ]; then
        pass "FS1 $2: the sum $(row_sum "$got") is at most the pool $4"
    else
        fail "FS1 $2: row sum exceeds the pool $4 (or no row)" "row=[$got]"
    fi
}
fs1_row 0 "pool 11, one unbounded run gets 11" "11" 11
fs1_row 1 "pool 11, two unbounded runs get 6 5" "6 5" 11
fs1_row 2 "pool 11, three unbounded runs get 4 4 3" "4 4 3" 11
fs1_row 3 "pool 11, demand 2 then unbounded gets 2 9" "2 9" 11
fs1_row 4 "pool 11, demand 2 and two unbounded get 2 5 4 (remainder in start order)" "2 5 4" 11
fs1_row 5 "pool 3, five runs get 1 1 1 0 0" "1 1 1 0 0" 3
fs1_row 6 "pool 1, three runs get 1 0 0" "1 0 0" 1
fs1_row 7 "pool 11, one run of demand 3 gets only 3" "3" 11
case_ran FS1

case_end

case_begin "fair-share-pool" "bin/lib/test-host-lanes-share.sh"

# ── FS2 the pool is the smallest max jobs per host among presence records, minus 1 ─
FS2C="$(new_cache)"
_n="$(now_epoch)"
mk_presence "$FS2C" "$LIVE_SLEEP.$((_n - 100)).201" "$LIVE_SLEEP" "$((_n - 100))" 8 1
lanes_drv "$FS2C" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 20 0; echo "rc=$?"
echo "granted=$THL_GRANTED"
n=0; for d in "$THL_CACHE_ROOT"/runs/run.*; do [ -d "$d" ] && n=$((n + 1)); done; echo "runs=$n"
[ -d "$THL_CACHE_ROOT/runs/run.$THL_TOKEN" ] && echo "own_record=1" || echo "own_record=0"
thl_release_all'
assert_eq "FS2 lease rc 0" "0" "$(kv_of "$OUT" rc)"
assert_eq "FS2 records of 12 and 8 give pool 7; the earlier run of demand 1 leaves 6" "6" "$(kv_of "$OUT" granted)"
assert_eq "FS2 two presence records while the lease is held" "2" "$(kv_of "$OUT" runs)"
assert_eq "FS2 the own record is runs/run.<THL_TOKEN>" "1" "$(kv_of "$OUT" own_record)"
assert_eq "FS2 release removes only the own record" "run.$LIVE_SLEEP.$((_n - 100)).201" "$(run_names "$FS2C")"
case_ran FS2

# ── FS15 the floor: max jobs per host 1 gives pool 1 ────────────────────────
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=1 -- '
thl_run_all_lease 5 0; echo "rc=$?"; echo "granted=$THL_GRANTED"; thl_release_all'
assert_eq "FS15 max jobs per host 1: a single run-all gets 1 lane" "1" "$(kv_of "$OUT" granted)"
FS15C="$(new_cache)"
_n="$(now_epoch)"
mk_presence "$FS15C" "$LIVE_SLEEP.$((_n + 100)).1501" "$LIVE_SLEEP" "$((_n + 100))" 1 1000
lanes_drv "$FS15C" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 5 0; echo "rc=$?"; echo "granted=$THL_GRANTED"; thl_release_all'
assert_eq "FS15 a later record of max jobs per host 1 floors the pool at 1; the first run gets 1" "1" "$(kv_of "$OUT" granted)"
case_ran FS15

case_end

case_begin "presence-reclaim" "bin/lib/test-host-lanes-share.sh"

# ── FS3 dead and TTL-stale records are not counted and are reclaimed; a live one survives ─
FS3C="$(new_cache)"
_n="$(now_epoch)"
_dp="$(dead_pid)"
FS3_DEAD="$_dp.$((_n - 200)).301"
FS3_STALE="$LIVE_SLEEP.$((_n - 1000)).302"
FS3_LIVE="$LIVE_SLEEP.$((_n + 100)).303"
mk_presence "$FS3C" "$FS3_DEAD" "$_dp" "$((_n - 200))" 12 1000
mk_presence "$FS3C" "$FS3_STALE" "$LIVE_SLEEP" "$((_n - 1000))" 12 1000 "$((_n - 1000))"
mk_presence "$FS3C" "$FS3_LIVE" "$LIVE_SLEEP" "$((_n + 100))" 12 1
lanes_drv "$FS3C" TEST_MAX_JOBS_PER_HOST=12 TEST_LANES_TTL=60 -- '
thl_run_all_lease 20 0; echo "rc=$?"; echo "granted=$THL_GRANTED"; thl_release_all'
assert_eq "FS3 only the live later record (demand 1) counts: granted 10 of pool 11" "10" "$(kv_of "$OUT" granted)"
assert_eq "FS3 dead and stale records are reclaimed; the live foreign-token record survives" "run.$FS3_LIVE" "$(run_names "$FS3C")"
assert_eq "FS3 no reclaim grave left" "0" "$(grave_count "$FS3C")"
case_ran FS3

# ── FS4 a waiting run-all has a presence record; exit 4 removes it ──────────
FS4C="$(new_cache)"
_n="$(now_epoch)"
FS4_EARLY="$LIVE_SLEEP.$((_n - 100)).401"
mk_presence "$FS4C" "$FS4_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
lanes_drv_bg "$FS4C" "$TMPDIR_BASE/fs4.out" "$TMPDIR_BASE/fs4.err" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES_WAIT_CAP=6 -- '
thl_run_all_lease 3 0; rc=$?; echo "rc=$rc"; thl_release_all; exit "$rc"'
_seen=0
for _i in 1 2 3 4 5 6 7 8; do
    [ "$(run_names "$FS4C" | wc -w)" -eq 2 ] && { _seen=1; break; }
    sleep 0.5
done
assert_eq "FS4 the waiting run-all holds its own presence record (2 records)" "1" "$_seen"
wait "$BG_PID"; _rc=$?
assert_eq "FS4 pool 1 taken by the earlier run: the wait ends with exit 4" "4" "$_rc"
grep -qF -- '[lanes] waiting for a fair share (1 runs ahead share 1 lanes)' "$TMPDIR_BASE/fs4.err" \
    && pass "FS4 stderr carries the fair-share waiting line" \
    || fail "FS4 no fair-share waiting line" "err=$(printf '%q' "$(cat "$TMPDIR_BASE/fs4.err")")"
assert_eq "FS4 after exit 4 only the earlier record remains" "run.$FS4_EARLY" "$(run_names "$FS4C")"
assert_eq "FS4 the waiting run took no lane" "" "$(lane_names "$FS4C")"
case_ran FS4

case_end

grp_done share-cases.sh
