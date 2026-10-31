#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/share-cases.sh — FS1-FS4, FS15, FS17-FS19:
# the run-all per-run lane cap computation, the pool from presence records, reclaim, the start-time
# wait, and the #2692 start width (slow start from 4, headroom, no memory trim, a burst).
# Self-position is 0-based in start order; an unbounded demand is written as 1000.

case_begin "per-run-cap-compute" "bin/lib/test-host-lanes-share.sh"

# ── FS1 the water-fill table; every row sums to at most the pool ────────────
# #2692 renamed the computation to _thl_per_run_cap_all; no fair-share function is left.
lanes_drv "$(new_cache)" -- '
for f in _thl_per_run_cap_all _thl_fair_share_all _thl_fair_share_compute; do
    declare -F "$f" >/dev/null 2>&1 && echo "fn_$f=1" || echo "fn_$f=0"
done'
assert_eq "FS1 the share lib defines _thl_per_run_cap_all" "1" "$(kv_of "$OUT" fn__thl_per_run_cap_all)"
assert_eq "FS1 _thl_fair_share_all is gone (renamed)" "0" "$(kv_of "$OUT" fn__thl_fair_share_all)"
assert_eq "FS1 _thl_fair_share_compute is gone (renamed)" "0" "$(kv_of "$OUT" fn__thl_fair_share_compute)"
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

case_begin "per-run-cap-pool" "bin/lib/test-host-lanes-share.sh"

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
assert_eq "FS2 records of 12 and 8 give pool 7: no sample, so the run starts at width 4" "4" "$(kv_of "$OUT" granted)"
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
assert_eq "FS3 dead and stale records hold nothing: the run starts at width 4 of pool 11" "4" "$(kv_of "$OUT" granted)"
assert_eq "FS3 dead and stale records are reclaimed; the live foreign-token record survives" "run.$FS3_LIVE" "$(run_names "$FS3C")"
assert_eq "FS3 no reclaim grave left" "0" "$(grave_count "$FS3C")"
case_ran FS3

# ── FS4 a waiting run-all has a presence record; exit 4 removes it ──────────
FS4C="$(new_cache)"
_n="$(now_epoch)"
FS4_EARLY="$LIVE_SLEEP.$((_n - 100)).401"
mk_presence "$FS4C" "$FS4_EARLY" "$LIVE_SLEEP" "$((_n - 100))" 2 1000
mk_slot "$FS4C" 1 "$LIVE_SLEEP" "$FS4_EARLY"
lanes_drv_bg "$FS4C" "$TMPDIR_BASE/fs4.out" "$TMPDIR_BASE/fs4.err" TEST_MAX_JOBS_PER_HOST=2 TEST_LANES_WAIT_CAP=6 -- '
thl_run_all_lease 3 0; rc=$?; echo "rc=$rc"; thl_release_all; exit "$rc"'
_seen=0
for _i in 1 2 3 4 5 6 7 8; do
    [ "$(run_names "$FS4C" | wc -w)" -eq 2 ] && { _seen=1; break; }
    sleep 0.5
done
assert_eq "FS4 the waiting run-all holds its own presence record (2 records)" "1" "$_seen"
wait "$BG_PID"; _rc=$?
assert_eq "FS4 the earlier run holds pool 1 (headroom 0): the wait ends with exit 4" "4" "$_rc"
assert_eq "FS4 after exit 4 only the earlier record remains" "run.$FS4_EARLY" "$(run_names "$FS4C")"
assert_eq "FS4 the waiting run took no lane; the earlier run's lane stays" "lane.1" "$(lane_names "$FS4C")"
case_ran FS4

case_end

case_begin "start-width" "bin/lib/test-host-lanes-share.sh"

# ── FS17 start width = min(4, requested, headroom) ──────────────────────────
FS17_SNIP='thl_run_all_lease "$WANT" 0; echo "rc=$?"; echo "granted=$THL_GRANTED"; thl_release_all'
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 WANT=11 -- "$FS17_SNIP"
assert_eq "FS17 no sample, pool 11: requested 11 starts at 4" "4" "$(kv_of "$OUT" granted)"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 WANT=3 -- "$FS17_SNIP"
assert_eq "FS17 requested 3 starts at 3" "3" "$(kv_of "$OUT" granted)"
# headroom = the fresh sample's pool minus the lanes live run-alls hold
FS17C="$(new_cache)"
_n="$(now_epoch)"
FS17_OTHER="$LIVE_SLEEP.$((_n - 100)).1701"
mk_presence "$FS17C" "$FS17_OTHER" "$LIVE_SLEEP" "$((_n - 100))" 12 1000
for _i in 1 2 3 4; do mk_slot "$FS17C" "$_i" "$LIVE_SLEEP" "$FS17_OTHER"; done
ls2_write "$FS17C" 0 pool=6
lanes_drv "$FS17C" TEST_MAX_JOBS_PER_HOST=12 WANT=11 -- "$FS17_SNIP"
assert_eq "FS17 sample pool 6, another run holds 4: headroom 2" "2" "$(kv_of "$OUT" granted)"
ls2_write "$FS17C" 0 pool=15
lanes_drv "$FS17C" TEST_MAX_JOBS_PER_HOST=12 WANT=11 -- "$FS17_SNIP"
assert_eq "FS17 control: sample pool 15, the same 4 held: start width 4" "4" "$(kv_of "$OUT" granted)"
ls2_write "$FS17C" 900 pool=5
lanes_drv "$FS17C" TEST_MAX_JOBS_PER_HOST=12 WANT=11 -- "$FS17_SNIP"
assert_eq "FS17 a stale sample (pool 5) is ignored: max(1, base - 1) 11 - 4 held leaves 4" "4" "$(kv_of "$OUT" granted)"
# the run-all per-run lane cap caps the start width: max-min over the demand of every live presence record (pool 11,
# no sample), a later record's share reserved though it holds nothing. fs17_fs <label> <want>
# <earlier> <later> [lanes the first earlier run holds]; every other record is unbounded (1000).
fs17_fs() {
    local c n i
    c="$(new_cache)"; n="$(now_epoch)"
    for ((i = 1; i <= $3; i++)); do mk_presence "$c" "$LIVE_SLEEP.$((n - 100 - i)).17$i" "$LIVE_SLEEP" "$((n - 100 - i))" 12 1000; done
    for ((i = 1; i <= $4; i++)); do mk_presence "$c" "$LIVE_SLEEP.$((n + 100 + i)).178$i" "$LIVE_SLEEP" "$((n + 100 + i))" 12 1000; done
    for ((i = 1; i <= ${5:-0}; i++)); do mk_slot "$c" "$i" "$LIVE_SLEEP" "$LIVE_SLEEP.$((n - 101)).171"; done
    lanes_drv "$c" TEST_MAX_JOBS_PER_HOST=12 WANT=11 -- "$FS17_SNIP"
    assert_eq "FS17 $1" "$2" "$(kv_of "$OUT" granted)"
}
fs17_fs "four earlier runs, none holding: caps 3 2 2 2 2, free 11: start width = per-run lane cap 2" 2 4 0
fs17_fs "two earlier runs, none holding: caps 4 4 3, free 11: start width = per-run lane cap 3" 3 2 0
fs17_fs "one earlier and two later runs, none holding: caps 3 3 3 2, the later caps reserved: 3" 3 1 2
fs17_fs "control: one earlier run, none holding: caps 6 5, free 11: start width 4" 4 1 0
fs17_fs "one earlier run holds 8: per-run lane cap 5 > free 3: start width = free lanes 3" 3 1 0 8
case_ran FS17

# ── FS18 memory never trims the start width (no spare-lane estimate) ────────
# Memory acts only through the claim holder's mem_cap on the per-run lane cap, never on a new run's
# start width: the start width stays 4 whatever the sample's free memory says.
FS18C="$(new_cache)"
ls2_write "$FS18C" 0 mem_avail_mb=9000 mem_total_mb=16384 mem_reserve_mb=2048 mem_scope=host
lanes_drv "$FS18C" TEST_MAX_JOBS_PER_HOST=16 WANT=11 -- "$FS17_SNIP"
assert_eq "FS18 free memory above the reserve: start width 4" "4" "$(kv_of "$OUT" granted)"
ls2_write "$FS18C" 0 mem_avail_mb=2000 mem_total_mb=16384 mem_reserve_mb=2048 mem_scope=host
lanes_drv "$FS18C" TEST_MAX_JOBS_PER_HOST=16 WANT=11 -- "$FS17_SNIP"
assert_eq "FS18 free memory below the reserve: start width still 4 (no trim)" "4" "$(kv_of "$OUT" granted)"
assert_eq "FS18 free memory below the reserve: the lease succeeds" "0" "$(kv_of "$OUT" rc)"
case_ran FS18

# ── FS19 a burst of four run-alls: the start widths sum to at most the pool ─
FS19C="$(new_cache)"
FS19_SUM=0
FS19_G=""
for _i in 1 2 3 4; do
    lanes_drv_bg "$FS19C" "$TMPDIR_BASE/fs19.$_i.out" "$TMPDIR_BASE/fs19.$_i.err" TEST_MAX_JOBS_PER_HOST=8 -- '
thl_run_all_lease 20 0; rc=$?; echo "granted=${THL_GRANTED:-0}"; echo "rc=$rc"; sleep 15; thl_release_all'
    eval "FS19_P$_i=\$BG_PID"
    wait_grep 10 "$TMPDIR_BASE/fs19.$_i.out" "rc=" || true
done
for _i in 1 2 3 4; do
    eval "wait \"\$FS19_P$_i\""
    _g="$(sed -n 's/^granted=//p' "$TMPDIR_BASE/fs19.$_i.out" | head -n 1)"
    [[ $_g =~ ^[0-9]+$ ]] || _g=0
    FS19_G="$FS19_G $_g"; FS19_SUM=$((FS19_SUM + _g))
done
assert_eq "FS19 run 1 starts at 4, run 2 at the headroom 3, runs 3 and 4 get 0" " 4 3 0 0" "$FS19_G"
[ "$FS19_SUM" -le 7 ] && [ "$FS19_SUM" -ge 1 ] && pass "FS19 the start widths sum to $FS19_SUM, within pool 7" \
    || fail "FS19 the start widths sum to $FS19_SUM (want 1..7)" "widths=[$FS19_G]"
case_ran FS19

case_end

grp_done share-cases.sh
