#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/rebalance-cases.sh — FS5-FS7, FS9-FS11, FS16:
# thl_rebalance shrink/grow, the heartbeat over grown lanes, the disabled paths and the
# held-set invariant of _thl_acquire_more / _thl_release_lanes (library sourced directly).

case_begin "rebalance" "bin/lib/test-host-lanes-share.sh"

# ── FS5 shrink: another record appears -> max(fair share, inflight) ─────────
FS5C="$(new_cache)"
lanes_drv "$FS5C" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" -- '
thl_run_all_lease 11 0; echo "rc=$?"; echo "g0=$THL_GRANTED"
s=$((THL_NOW + 100)); mk_presence "$THL_CACHE_ROOT" "$LIVE.$s.501" "$LIVE" "$s" 12 1000
thl_rebalance 0; echo "g1=$THL_GRANTED"; drv_inv inv1
thl_release_all'
assert_eq "FS5 alone: 11 lanes of pool 11" "11" "$(kv_of "$OUT" g0)"
assert_eq "FS5 a later record appears: the first run shrinks to its share 6" "6" "$(kv_of "$OUT" g1)"
assert_eq "FS5 held set stays consistent after the shrink" "g6s6o6" "$(kv_of "$OUT" inv1)"
has_line "$OUT$ERR" "lanes: width 11 -> 6 (fair share among 2 runs)" \
    && pass "FS5 the width line names the shrink and the run count" \
    || fail "FS5 no 'lanes: width 11 -> 6 (fair share among 2 runs)' line" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
FS5I="$(new_cache)"
lanes_drv "$FS5I" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" -- '
thl_run_all_lease 11 0
s=$((THL_NOW + 100)); mk_presence "$THL_CACHE_ROOT" "$LIVE.$s.502" "$LIVE" "$s" 12 1000
thl_rebalance 8; echo "g1=$THL_GRANTED"; drv_inv inv1
thl_release_all'
assert_eq "FS5 inflight 8: running jobs are never stopped, so 8 lanes stay" "8" "$(kv_of "$OUT" g1)"
assert_eq "FS5 inflight 8: held set consistent" "g8s8o8" "$(kv_of "$OUT" inv1)"
case_ran FS5

# ── FS6 grow: the other record disappears -> back to the full pool ──────────
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=12 "LIVE=$LIVE_SLEEP" -- '
thl_run_all_lease 11 0
s=$((THL_NOW + 100)); tok="$LIVE.$s.601"; mk_presence "$THL_CACHE_ROOT" "$tok" "$LIVE" "$s" 12 1000
thl_rebalance 0; echo "g1=$THL_GRANTED"
rm -rf "$THL_CACHE_ROOT/runs/run.$tok"
thl_rebalance 0; echo "g2=$THL_GRANTED"; drv_inv inv2
thl_release_all'
assert_eq "FS6 shrunk to 6 first" "6" "$(kv_of "$OUT" g1)"
assert_eq "FS6 the other run leaves: grows back to 11" "11" "$(kv_of "$OUT" g2)"
assert_eq "FS6 held set consistent after the growth" "g11s11o11" "$(kv_of "$OUT" inv2)"
has_line "$OUT$ERR" "lanes: width 6 -> 11" && pass "FS6 the width line names the growth" \
    || fail "FS6 no 'lanes: width 6 -> 11' line" "err=$(printf '%q' "$ERR")"
case_ran FS6

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

# ── FS16 thl_dispatch_wait: a deadline bounds the fair-share-0 wait ─────────
FS16_SNIP='
thl_run_all_lease 1 0
s=$((THL_PRESENCE_START - 100)); tok="$LIVE.$s.1601"; mk_presence "$THL_CACHE_ROOT" "$tok" "$LIVE" "$s" 2 1000
thl_rebalance 0; echo "w0=$THL_WIDTH"
bgp=""
[ "$MODE" = control ] && { ( sleep 2; rm -rf "$THL_CACHE_ROOT/runs/run.$tok" ) & bgp=$!; }
t=$SECONDS
if [ "$MODE" = control ]; then thl_dispatch_wait 0 0; else thl_dispatch_wait 2 "$t"; fi
echo "rc=$?"; echo "el=$((SECONDS - t))"; echo "w1=$THL_WIDTH"
[ -n "$bgp" ] && wait "$bgp"
thl_release_all'
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=deadline -- "$FS16_SNIP"
assert_eq "FS16 an earlier run holds pool 1: the width drops to 0" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 deadline 2: thl_dispatch_wait gives up with rc 1" "1" "$(kv_of "$OUT" rc)"
_el="$(kv_of "$OUT" el)"
[[ "$_el" =~ ^[0-9]+$ ]] && [ "$_el" -ge 2 ] && [ "$_el" -le 5 ] \
    && pass "FS16 deadline 2: the wait ends after ${_el}s (bounded, not before the deadline)" \
    || fail "FS16 deadline 2: elapsed ${_el:-?}s outside [2,5]" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "FS16 deadline 2: the width stays 0" "0" "$(kv_of "$OUT" w1)"
has_line "$ERR" "fair share 0 among 2 runs (pool 1 lanes); waiting for a lane" \
    && pass "FS16 the dispatch-wait line names the run count and the pool" \
    || fail "FS16 no 'fair share 0 among 2 runs (pool 1 lanes)' line" "err=$(printf '%q' "$ERR")"
lanes_drv "$(new_cache)" TEST_MAX_JOBS_PER_HOST=2 "LIVE=$LIVE_SLEEP" MODE=control -- "$FS16_SNIP"
assert_eq "FS16 control: width 0 before the wait" "0" "$(kv_of "$OUT" w0)"
assert_eq "FS16 control (no deadline): the wait returns 0 once the earlier run leaves" "0" "$(kv_of "$OUT" rc)"
_w1="$(kv_of "$OUT" w1)"
[[ "$_w1" =~ ^[0-9]+$ ]] && [ "$_w1" -ge 1 ] && pass "FS16 control: the width is back to $_w1" \
    || fail "FS16 control: width ${_w1:-?} after the wait" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
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

grp_done rebalance-cases.sh
