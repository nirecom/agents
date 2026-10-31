#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/rebalance-cases.sh — FS5-FS7, FS9-FS11, FS16,
# FS20, FS21: thl_rebalance following the own load/sample row (#2692), the width line, the
# heartbeat over grown lanes, the disabled paths, the held-set invariant of _thl_acquire_more /
# _thl_release_lanes (library sourced directly), a stale sample -> tick -> rebalance chain and
# FS22 thl_sample_new / _THL_REB_AT (a sample refresh the run-all wait loop reacts to).
# load/.claim is held, so no tick rewrites rows (FS21 frees it for its one tick).

case_begin "rebalance" "bin/lib/test-host-lanes-share.sh"

# ── FS5 shrink: the own sample row drops to 2 -> max(row width, inflight) ───
FS5_SNIP='
thl_run_all_lease 11 0; echo "rc=$?"; echo "g0=$THL_GRANTED"
s=$((THL_NOW + 100)); tok="$LIVE.$s.501"; mk_presence "$THL_CACHE_ROOT" "$tok" "$LIVE" "$s" 12 1000
ls2_write "$THL_CACHE_ROOT" 0 pool=3 -- "$THL_TOKEN=2 15 2 per-run-cap" "$tok=1 15 1 per-run-cap"
thl_rebalance "$INFLIGHT"; echo "g1=$THL_GRANTED"; drv_inv inv1
thl_release_all'
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" INFLIGHT=0 -- "$FS5_SNIP"
assert_eq "FS5 alone, no sample: starts at 4" "4" "$(kv_of "$OUT" g0)"
assert_eq "FS5 the own row says width 2: the run shrinks to 2" "2" "$(kv_of "$OUT" g1)"
assert_eq "FS5 held set stays consistent after the shrink" "g2s2o2" "$(kv_of "$OUT" inv1)"
has_line "$OUT$ERR" "lanes: width 4 -> 2 (per-run lane cap 2 among 2 runs, decided by per-run-cap)" \
    && pass "FS5 the width line names the per-run lane cap, the run count and decided_by" \
    || fail "FS5 no 'lanes: width 4 -> 2 (per-run lane cap 2 among 2 runs, decided by per-run-cap)' line" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" INFLIGHT=3 -- "$FS5_SNIP"
assert_eq "FS5 inflight 3: running jobs are never stopped, so 3 lanes stay" "3" "$(kv_of "$OUT" g1)"
assert_eq "FS5 inflight 3: held set consistent" "g3s3o3" "$(kv_of "$OUT" inv1)"
case_ran FS5

# ── FS6 grow by the row; no row keeps the width; the request caps the row ───
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 11 0; echo "g0=$THL_GRANTED"
ls2_write "$THL_CACHE_ROOT" 0 pool=11 -- "$THL_TOKEN=8 15 11 slow-start"
thl_rebalance 0; echo "g1=$THL_GRANTED"; drv_inv inv1
rm -f "$THL_CACHE_ROOT/load/sample"
thl_rebalance 0; echo "g2=$THL_GRANTED"
ls2_write "$THL_CACHE_ROOT" 0 pool=11 runs=1 -- "1.1.1=8 15 11 slow-start"
thl_rebalance 0; echo "g3=$THL_GRANTED"
ls2_write "$THL_CACHE_ROOT" 0 pool=15 -- "$THL_TOKEN=15 15 15 per-run-cap"
thl_rebalance 0; echo "g4=$THL_GRANTED"; drv_inv inv4
thl_release_all'
assert_eq "FS6 starts at 4" "4" "$(kv_of "$OUT" g0)"
assert_eq "FS6 the own row says 8: grows to 8" "8" "$(kv_of "$OUT" g1)"
assert_eq "FS6 held set consistent after the growth" "g8s8o8" "$(kv_of "$OUT" inv1)"
has_line "$OUT$ERR" "lanes: width 4 -> 8 (per-run lane cap 11 among 1 runs, decided by slow-start)" \
    && pass "FS6 the grow line names the per-run lane cap and slow-start" \
    || fail "FS6 no 'lanes: width 4 -> 8 (per-run lane cap 11 among 1 runs, decided by slow-start)' line" "err=$(printf '%q' "$ERR")"
assert_eq "FS6 no sample: the width is held at 8 (never grows nor drops)" "8" "$(kv_of "$OUT" g2)"
assert_eq "FS6 a sample without the own row: the width is held at 8" "8" "$(kv_of "$OUT" g3)"
assert_eq "FS6 a row of 15 is capped by the request 11" "11" "$(kv_of "$OUT" g4)"
assert_eq "FS6 held set consistent at 11" "g11s11o11" "$(kv_of "$OUT" inv4)"
case_ran FS6

# ── FS20 the width line carries load scale-in and memory cap when they act ──
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 11 0
ls2_write "$THL_CACHE_ROOT" 0 pool=8 scale_in=2 above=2 -- "$THL_TOKEN=3 2 3 cpu-load-limit"
thl_rebalance 0; echo "g1=$THL_GRANTED"
ls2_write "$THL_CACHE_ROOT" 0 pool=2 mem_cap=2 mem_avail_mb=1500 mem_total_mb=16384 mem_reserve_mb=2048 mem_scope=host -- "$THL_TOKEN=2 2 2 memory-limit"
thl_rebalance 0; echo "g2=$THL_GRANTED"
thl_release_all'
assert_eq "FS20 cpu-load-limit row: 3" "3" "$(kv_of "$OUT" g1)"
has_line "$ERR" "lanes: width 4 -> 3 (per-run lane cap 3 among 1 runs, decided by cpu-load-limit, load scale-in 2)" \
    && pass "FS20 the cpu-load-limit width line keeps the 'load scale-in 2' part" \
    || fail "FS20 no 'width 4 -> 3 (... decided by cpu-load-limit, load scale-in 2)' line" "err=$(printf '%q' "$ERR")"
assert_eq "FS20 memory-limit row: 2" "2" "$(kv_of "$OUT" g2)"
has_line "$ERR" "lanes: width 3 -> 2 (per-run lane cap 2 among 1 runs, decided by memory-limit, memory cap 2)" \
    && pass "FS20 the memory-limit width line names the memory cap" \
    || fail "FS20 no 'width 3 -> 2 (... decided by memory-limit, memory cap 2)' line" "err=$(printf '%q' "$ERR")"
case_ran FS20

# ── FS7 the heartbeat refreshes grown lanes and the presence record ─────────
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 TEST_LANES_HEARTBEAT=1 -- '
thl_run_all_lease 3 0
_thl_acquire_more run-all 5 1 11 asc; echo "g=$THL_GRANTED"
old=$((THL_NOW - 500))
printf "%s\n" "$old" > "$THL_CACHE_ROOT/slots/lane.5/hb"
printf "%s\n" "$old" > "$THL_CACHE_ROOT/runs/run.$THL_TOKEN/hb"
sleep 4
_thl_now
l=$(cat "$THL_CACHE_ROOT/slots/lane.5/hb"); r=$(cat "$THL_CACHE_ROOT/runs/run.$THL_TOKEN/hb")
[ $((THL_NOW - l)) -le 10 ] && echo "lane5_fresh=1" || echo "lane5_fresh=0"
[ $((THL_NOW - r)) -le 10 ] && echo "run_fresh=1" || echo "run_fresh=0"
thl_release_all'
assert_eq "FS7 _thl_acquire_more grows the held set to 5" "5" "$(kv_of "$OUT" g)"
assert_eq "FS7 the heartbeat refreshes lane.5, taken after it started" "1" "$(kv_of "$OUT" lane5_fresh)"
assert_eq "FS7 the heartbeat refreshes the own presence record" "1" "$(kv_of "$OUT" run_fresh)"
case_ran FS7

# ── FS16 thl_dispatch_wait: a deadline bounds the width-0 wait ──────────────
# The own row says width 0. control: the row turns 1; stale*: no usable row arrives (pool 1),
# so the start width is min(4, per-run lane cap by demand, free lanes). The other run starts at OFF.
FS16_SNIP='
thl_run_all_lease "${DESIRED:-1}" 0
s=$((THL_PRESENCE_START + ${OFF:--100})); tok="$LIVE.$s.1601"; mk_presence "$THL_CACHE_ROOT" "$tok" "$LIVE" "$s" 2 "${ODEM:-1000}"
ls2_write "$THL_CACHE_ROOT" 0 pool=1 -- "$tok=1 15 1 per-run-cap" "$THL_TOKEN=0 15 0 per-run-cap"
thl_rebalance 0; echo "w0=$THL_WIDTH"
bgp=""
case "$MODE" in
    control) ( sleep 2; ls2_write "$THL_CACHE_ROOT" 0 pool=1 -- "$THL_TOKEN=1 15 1 per-run-cap" ) & bgp=$! ;;
    stale*) ( sleep 2; ls2_write "$THL_CACHE_ROOT" 900 pool=1 -- "$THL_TOKEN=0 15 0 per-run-cap" ) & bgp=$! ;;
esac
t=$SECONDS
case "$MODE" in deadline) thl_dispatch_wait 2 "$t" ;; stale*) thl_dispatch_wait 5 "$t" ;; *) thl_dispatch_wait 0 0 ;; esac
echo "rc=$?"; echo "el=$((SECONDS - t))"; echo "w1=$THL_WIDTH"; echo "g1=$THL_GRANTED"; echo "own=$(own_lanes "$THL_TOKEN")"
[ -n "$bgp" ] && wait "$bgp"
thl_release_all'
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=deadline -- "$FS16_SNIP"
assert_eq "FS16 the own row says 0: the width drops to 0" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 deadline 2: thl_dispatch_wait gives up with rc 1" "1" "$(kv_of "$OUT" rc)"
_el="$(kv_of "$OUT" el)"
[[ "$_el" =~ ^[0-9]+$ ]] && [ "$_el" -ge 2 ] && [ "$_el" -le 5 ] \
    && pass "FS16 deadline 2: the wait ends after ${_el}s (bounded, not before the deadline)" \
    || fail "FS16 deadline 2: elapsed ${_el:-?}s outside [2,5]" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "FS16 deadline 2: the width stays 0" "0" "$(kv_of "$OUT" w1)"
has_line "$ERR" "per-run lane cap 0 among 2 runs (pool 1 lanes); waiting for a lane" \
    && pass "FS16 the dispatch-wait line names the run count and the pool" \
    || fail "FS16 no 'per-run lane cap 0 among 2 runs (pool 1 lanes)' line" "err=$(printf '%q' "$ERR")"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=control -- "$FS16_SNIP"
assert_eq "FS16 control: width 0 before the wait" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 control (no deadline): the wait returns 0 once the own row turns 1" "0" "$(kv_of "$OUT" rc)"
assert_eq "FS16 control: the width is back to 1" "1" "$(kv_of "$OUT" w1)"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=stale -- "$FS16_SNIP"
assert_eq "FS16 stale: width 0 before the wait" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 stale: the earlier run (demand 1000) keeps its reserved share, so the wait runs to the deadline (rc 1)" "1" "$(kv_of "$OUT" rc)"
assert_eq "FS16 stale: per-run lane cap 0 caps the start width, so the width stays 0" "0" "$(kv_of "$OUT" w1)"
assert_eq "FS16 stale: the unused lane is not taken (granted 0)" "0" "$(kv_of "$OUT" g1)"
assert_eq "FS16 stale: no lane carries the own token" "0" "$(kv_of "$OUT" own)"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=stale-early DESIRED=1000 OFF=100 ODEM=1 -- "$FS16_SNIP"
assert_eq "FS16 stale-early: width 0 before the wait" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 stale-early: the earlier run (demand 1000) has per-run lane cap 1, so the wait ends (rc 0)" "0" "$(kv_of "$OUT" rc)"
assert_eq "FS16 stale-early: the earlier run takes the 1 free lane" "1" "$(kv_of "$OUT" w1)"
assert_eq "FS16 stale-early: one lane carries the own token" "1" "$(kv_of "$OUT" own)"
case_ran FS16

case_end

case_begin "rebalance-disabled" "bin/lib/test-host-lanes-share.sh"

# ── FS9 TEST_LANES=off, nested, and a degraded lease never rebalance ────────
FS9_SNIP='
thl_run_all_lease 5 0; echo "g0=$THL_GRANTED"
s=$(( $(date +%s) + 100 )); mk_presence "${THL_CACHE_ROOT:-$RUN_ALL_CACHE_DIR}" "$LIVE.$s.901" "$LIVE" "$s" 12 1000
thl_rebalance 0; echo "rb=$?"; echo "g1=$THL_GRANTED"; echo "deg=${THL_LANES_DEGRADED:-0}"
thl_release_all'
for _m in off held; do
    _c="$(new_cache)"
    if [ "$_m" = off ]; then _e="TEST_LANES=off"; else _e="TEST_LANES_HELD=123"; fi
    lanes_drv "$_c" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" "$_e" -- "$FS9_SNIP"
    assert_eq "FS9 $_m: thl_rebalance returns 0" "0" "$(kv_of "$OUT" rb)"
    assert_eq "FS9 $_m: the width is untouched by thl_rebalance" "$(kv_of "$OUT" g0)" "$(kv_of "$OUT" g1)"
    assert_eq "FS9 $_m: the requested width 5 stands" "5" "$(kv_of "$OUT" g1)"
    _own="$(run_names "$_c" | tr ' ' '\n' | grep -vc '\.901$' || true)"
    assert_eq "FS9 $_m: no presence record of its own" "0" "$_own"
    assert_eq "FS9 $_m: no lane created" "" "$(lane_names "$_c")"
done
FS9D="$(new_cache)"
printf 'not a directory\n' > "$FS9D/slots"
lanes_drv "$FS9D" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" -- "$FS9_SNIP"
assert_eq "FS9 slots/ cannot be created: THL_LANES_DEGRADED=1" "1" "$(kv_of "$OUT" deg)"
assert_eq "FS9 degraded: thl_rebalance leaves the width at 5" "5" "$(kv_of "$OUT" g1)"
has_line "$ERR" "running without a lane" && pass "FS9 degraded: the existing notice is printed" \
    || fail "FS9 degraded: no 'running without a lane' notice" "err=$(printf '%q' "$ERR")"
case_ran FS9

case_end

case_begin "held-set-invariant" "bin/lib/test-host-lanes-share.sh"

# ── FS10 acquire 3 -> more 6 -> release 4 -> more 5 -> release_all ──────────
FS10C="$(new_cache)"
lanes_drv "$FS10C" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 3 0; tok0="$THL_TOKEN"; drv_inv a; echo "a_slots=$THL_SLOTS"
_thl_acquire_more run-all 6 1 11 asc; drv_inv b; echo "b_slots=$THL_SLOTS"
[ "$THL_TOKEN" = "$tok0" ] && echo "b_tok=same" || echo "b_tok=changed"
_thl_release_lanes 4; drv_inv c; echo "c_slots=$THL_SLOTS"
n=""; for d in "$THL_CACHE_ROOT"/slots/lane.*; do [ -d "$d" ] && n="$n ${d##*/}"; done; echo "c_disk=${n# }"
_thl_acquire_more run-all 5 1 11 asc; drv_inv d
[ "$THL_TOKEN" = "$tok0" ] && echo "d_tok=same" || echo "d_tok=changed"
thl_release_all; echo "e_own=$(own_lanes "$tok0")"'
assert_eq "FS10 lease 3: invariant" "g3s3o3" "$(kv_of "$OUT" a)"
assert_eq "FS10 lease 3: lanes 1 2 3" "1 2 3" "$(kv_of "$OUT" a_slots)"
assert_eq "FS10 acquire_more to 6: invariant" "g6s6o6" "$(kv_of "$OUT" b)"
assert_eq "FS10 acquire_more to 6: lanes 1..6 in THL_SLOTS" "1 2 3 4 5 6" "$(printf '%s\n' $(kv_of "$OUT" b_slots) | sort -n | tr '\n' ' ' | sed 's/ $//')"
assert_eq "FS10 acquire_more keeps THL_TOKEN" "same" "$(kv_of "$OUT" b_tok)"
assert_eq "FS10 release 4: invariant" "g2s2o2" "$(kv_of "$OUT" c)"
assert_eq "FS10 release 4: the highest-numbered four go first" "1 2" "$(kv_of "$OUT" c_slots)"
assert_eq "FS10 release 4: lanes 1 2 remain on disk" "lane.1 lane.2" "$(kv_of "$OUT" c_disk)"
assert_eq "FS10 acquire_more to 5: invariant" "g5s5o5" "$(kv_of "$OUT" d)"
assert_eq "FS10 second acquire_more keeps THL_TOKEN" "same" "$(kv_of "$OUT" d_tok)"
assert_eq "FS10 release_all: no lane of the token left" "0" "$(kv_of "$OUT" e_own)"
assert_eq "FS10 release_all: slots/ empty" "" "$(lane_names "$FS10C")"
case_ran FS10

# ── FS11 a lane re-taken by another token survives partial and full release ─
FS11C="$(new_cache)"
lanes_drv "$FS11C" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" -- '
thl_run_all_lease 3 0
mk_slot "$THL_CACHE_ROOT" 3 "$LIVE" "$LIVE.1.1111"
_thl_release_lanes 1; echo "slots=$THL_SLOTS"; echo "g=$THL_GRANTED"
[ -d "$THL_CACHE_ROOT/slots/lane.3" ] && echo "kept=1" || echo "kept=0"
thl_release_all'
assert_eq "FS11 the foreign-token lane leaves THL_SLOTS" "1 2" "$(kv_of "$OUT" slots)"
assert_eq "FS11 THL_GRANTED drops by one" "2" "$(kv_of "$OUT" g)"
assert_eq "FS11 _thl_release_lanes leaves the foreign lane on disk" "1" "$(kv_of "$OUT" kept)"
assert_eq "FS11 thl_release_all leaves it too" "lane.3" "$(lane_names "$FS11C")"
case_ran FS11

case_end

case_begin "rebalance-after-stale-tick" "bin/lib/test-host-lanes-share.sh"

# ── FS21 stale sample -> tick -> rebalance (the ST2 setup of feature-2692) ──
# Run 1 (own, start earlier, 12 lanes) and run 2 (3 lanes) with a 20 s old schema-2 sample,
# heartbeat 2 s, 16 CPUs. Stale: the width stays 12; after one tick the row is 8, so 8 lanes.
FS21_CPU="$TMPDIR_BASE/cpu-shim-16"
cpu_shim "$FS21_CPU" 16
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=16 TEST_LANES_HEARTBEAT=2 "LIVE=$LIVE_SLEEP" "PATH=$FS21_CPU:$PATH" -- '
thl_run_all_lease 12 0
ls2_write "$THL_CACHE_ROOT" 0 -- "$THL_TOKEN=12 15 12 slow-start"
thl_rebalance 0; echo "w0=$THL_WIDTH"; echo "own0=$(own_lanes)"
s=$((THL_PRESENCE_START + 100)); tok="$LIVE.$s.2101"; mk_presence "$THL_CACHE_ROOT" "$tok" "$LIVE" "$s" 16 1000
for i in 13 14 15; do mk_slot "$THL_CACHE_ROOT" "$i" "$LIVE" "$tok"; done
ls2_write "$THL_CACHE_ROOT" 20 -- "$THL_TOKEN=12 12 15 per-run-cap" "$tok=3 6 7 slow-start"
thl_rebalance 0; echo "w1=$THL_WIDTH"; echo "own1=$(own_lanes)"
kill "$THL_HB_PID" 2>/dev/null; wait "$THL_HB_PID" 2>/dev/null
rmdir "$THL_CACHE_ROOT/load/.claim"
thl_load_tick
echo "row=$(sed -n "s/^alloc\.${THL_TOKEN//./\\.}=//p" "$THL_CACHE_ROOT/load/sample")"
thl_rebalance 0; echo "w2=$THL_WIDTH"; echo "own2=$(own_lanes)"; echo "other2=$(own_lanes "$tok")"
thl_release_all'
assert_eq "FS21 setup: a fresh row of 12 grows the run to width 12" "12" "$(kv_of "$OUT" w0)"
assert_eq "FS21 setup: the run holds 12 lanes" "12" "$(kv_of "$OUT" own0)"
assert_eq "FS21 control, stale sample without a tick: the width stays 12" "12" "$(kv_of "$OUT" w1)"
assert_eq "FS21 control, stale sample without a tick: 12 lanes stay held" "12" "$(kv_of "$OUT" own1)"
assert_eq "FS21 the tick cuts the stale row 12/12 to its share 8, ssthresh 12 kept" "8 12 8 per-run-cap" "$(kv_of "$OUT" row)"
assert_eq "FS21 after the tick: thl_rebalance shrinks the width 12 -> 8" "8" "$(kv_of "$OUT" w2)"
assert_eq "FS21 after the tick: the run holds 8 lanes" "8" "$(kv_of "$OUT" own2)"
assert_eq "FS21 after the tick: run 2 keeps its 3 lanes" "3" "$(kv_of "$OUT" other2)"
has_line "$ERR" "lanes: width 12 -> 8 (per-run lane cap 8 among 2 runs, decided by per-run-cap)" \
    && pass "FS21 the width line names the shrink 12 -> 8 by per-run-cap" \
    || fail "FS21 no 'lanes: width 12 -> 8 (per-run lane cap 8 among 2 runs, decided by per-run-cap)' line" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
case_ran FS21

case_end

case_begin "sample-new" "bin/lib/test-host-lanes-share.sh"

# ── FS22 thl_sample_new: a valid sample whose measured_at differs from _THL_REB_AT ──
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 4 0
declare -F thl_sample_new >/dev/null 2>&1 || { echo "impl=0"; thl_release_all; exit 0; }
echo "impl=1"; S="$THL_CACHE_ROOT/load/sample"; at() { sed -n "s/^measured_at=//p" "$S"; }
rm -f "$S"; thl_sample_new; echo "a=$?"
ls2_write "$THL_CACHE_ROOT" 0 -- "$THL_TOKEN=4 15 4 slow-start"; echo "at1=$(at)"
thl_sample_new; echo "b=$?"
thl_rebalance 0; echo "reb1=${_THL_REB_AT:-}"; thl_sample_new; echo "c=$?"
ls2_write "$THL_CACHE_ROOT" 5 -- "$THL_TOKEN=4 15 4 slow-start"; echo "at2=$(at)"
thl_sample_new; echo "d=$?"
thl_rebalance 0; echo "reb2=${_THL_REB_AT:-}"
printf "not a sample\n" > "$S"; thl_sample_new; echo "e=$?"
thl_rebalance 0; echo "reb3=${_THL_REB_AT:-}"
ls2_write "$THL_CACHE_ROOT" 10 -- "$THL_TOKEN=4 15 4 slow-start"
THL_LANES_DEGRADED=1; thl_sample_new; echo "f=$?"; THL_LANES_DEGRADED=0
tok="$THL_TOKEN"; THL_TOKEN=""; thl_sample_new; echo "g=$?"; THL_TOKEN="$tok"
thl_sample_new; echo "h=$?"
thl_release_all'
FS22_OUT="$OUT"; FS22_ERR="$ERR"; FS22_RC="$RC"
# Stale: valid but past 3 periods (default heartbeat 60), measured_at unlike _THL_REB_AT.
# A sample counts as new only when it is fresh, so thl_sample_new returns 1 here.
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 -- '
thl_run_all_lease 4 0; echo "w0=$THL_WIDTH"; echo "o0=$(own_lanes)"
ls2_write "$THL_CACHE_ROOT" 200 pool=1 -- "$THL_TOKEN=1 15 1 per-run-cap"
if declare -F thl_sample_new >/dev/null 2>&1; then thl_sample_new; echo "sn=$?"; fi
thl_rebalance 0; echo "ws=$THL_WIDTH"; echo "os=$(own_lanes)"
thl_release_all'
assert_eq "FS22 stale setup: the lease starts at width 4" "4" "$(kv_of "$OUT" w0)"
assert_eq "FS22 a valid sample past 3 periods with a new measured_at: THL_WIDTH stays" "$(kv_of "$OUT" w0)" "$(kv_of "$OUT" ws)"
assert_eq "FS22 a valid sample past 3 periods: the held lanes stay" "$(kv_of "$OUT" o0)" "$(kv_of "$OUT" os)"
_sn="$(kv_of "$OUT" sn)"
OUT="$FS22_OUT"; ERR="$FS22_ERR"; RC="$FS22_RC"
if [ "$(kv_of "$OUT" impl)" = 1 ]; then
    _at1="$(kv_of "$OUT" at1)"; _at2="$(kv_of "$OUT" at2)"
    assert_eq "FS22 (a) no sample file: thl_sample_new returns 1" "1" "$(kv_of "$OUT" a)"
    assert_eq "FS22 (b) a valid fresh sample before any thl_rebalance: returns 0" "0" "$(kv_of "$OUT" b)"
    assert_eq "FS22 (c) thl_rebalance records the sample's measured_at in _THL_REB_AT" "$_at1" "$(kv_of "$OUT" reb1)"
    assert_eq "FS22 (c) the same measured_at again: returns 1" "1" "$(kv_of "$OUT" c)"
    [ -n "$_at1" ] && [ "$_at1" != "$_at2" ] && pass "FS22 (d) setup: the rewritten sample carries another measured_at" \
        || fail "FS22 (d) setup: measured_at did not change" "at1=$_at1 at2=$_at2"
    assert_eq "FS22 (d) a different measured_at: returns 0" "0" "$(kv_of "$OUT" d)"
    assert_eq "FS22 (d) thl_rebalance moves _THL_REB_AT to the new measured_at" "$_at2" "$(kv_of "$OUT" reb2)"
    assert_eq "FS22 (e) a malformed sample: returns 1" "1" "$(kv_of "$OUT" e)"
    assert_eq "FS22 (e) thl_rebalance over a malformed sample leaves _THL_REB_AT" "$_at2" "$(kv_of "$OUT" reb3)"
    assert_eq "FS22 (f) THL_LANES_DEGRADED=1: returns 1 even for a new sample" "1" "$(kv_of "$OUT" f)"
    assert_eq "FS22 (f) no THL_TOKEN: returns 1 even for a new sample" "1" "$(kv_of "$OUT" g)"
    assert_eq "FS22 (f) control: the same new sample with a token and lanes: returns 0" "0" "$(kv_of "$OUT" h)"
    assert_eq "FS22 (g) a valid sample past 3 periods with a new measured_at: returns 1" "1" "$_sn"
else
    fail "FS22 thl_sample_new is not defined (not implemented yet)" "rc=$RC out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
fi
case_ran FS22

case_end

grp_done rebalance-cases.sh
