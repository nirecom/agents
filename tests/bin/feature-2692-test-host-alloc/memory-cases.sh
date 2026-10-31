#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/memory-cases.sh — MC1-MC12: the memory cap one mode-on
# tick writes (reserve, per-lane floor 512, the shortfall divided by
# per_lane = max(512, ceil(mem_tests_mb / H)), the same as adding the test tree rss back), and
# MC12 the cap lifting on a later tick of the same run. Memory acts only through mem_cap: there
# is no spare-lane estimate (no mem_spare_lanes key, no trim of a start width or a growth).
# Run 1 holds H lanes under a previous row of width 4 that it does not use up when H < 4, so the
# row never grows.

# mc_tick <cache> <held> <spec> — run 1 with <held> lanes and a fresh previous row "4 15 15
# slow-start" (no row when held is 0), one mode-on tick against <spec>.
mc_tick() {
    local c="$1"
    al_run "$c" 1
    [ "$2" -gt 0 ] && al_lanes "$c" 1 "$2" 1
    if [ "$2" -gt 0 ]; then al_prev "$c" -- "$(row 1 4 15 15 slow-start)"; else al_prev "$c"; fi
    al_snaps "$c" "$c/snaps" "$3"
    al_drv "$c" "$c/snaps" "$ON" -- 'al_tick 1'
}

case_begin "memory-sufficient" "bin/lib/test-host-alloc.sh"
# ── MC1 avail at or above the reserve: no cap, and no spare-lane key ────────
mc_tick "$(new_cache)" 2 "0 $(mb 4096) $GIB16 host"
expect_eq "MC1 mem_avail_mb from the snapshot" "4096" "$(tk 1 mem_avail_mb)"
expect_eq "MC1 mem_total_mb from the snapshot" "16384" "$(tk 1 mem_total_mb)"
expect_eq "MC1 mem_scope host" "host" "$(tk 1 mem_scope)"
expect_eq "MC1 reserve = max(2048, 10% of 16384)" "2048" "$(tk 1 mem_reserve_mb)"
expect_eq "MC1 no memory cap" "none" "$(tk 1 mem_cap)"
expect_eq "MC1 the sample carries no mem_spare_lanes key" "" "$(tk 1 mem_spare_lanes)"
expect_eq "MC1 pool stays 15" "15" "$(tk 1 pool)"
expect_eq "MC1 a row not used up keeps its width" "4 15 15 slow-start" "$(trow 1 1)"
case_ran MC1
case_end

case_begin "memory-short" "bin/lib/test-host-alloc.sh"
# ── MC2 512 MB short with H 4: cap 3, the run cut to it, decided by memory-limit ─
mc_tick "$(new_cache)" 4 "0 $(mb 1536) $GIB16 host"
expect_eq "MC2 cap = max(1, 4 - ceil(512 / 512))" "3" "$(tk 1 mem_cap)"
expect_eq "MC2 pool = min(15, cap)" "3" "$(tk 1 pool)"
expect_eq "MC2 width 4 -> 3, ssthresh max(2, 3), decided by memory-limit" "3 3 3 memory-limit" "$(trow 1 1)"
case_ran MC2

# ── MC3 1536 MB short: three lanes go; with H 0 the cap is still 1 ──────────
mc_tick "$(new_cache)" 4 "0 $(mb 512) $GIB16 host"
expect_eq "MC3 cap = max(1, 4 - 3)" "1" "$(tk 1 mem_cap)"
mc_tick "$(new_cache)" 0 "0 $(mb 512) $GIB16 host"
expect_eq "MC3 H 0: cap floors at 1" "1" "$(tk 1 mem_cap)"
expect_eq "MC3 H 0: pool 1" "1" "$(tk 1 pool)"
case_ran MC3
case_end

case_begin "memory-heavy-lane" "bin/lib/test-host-alloc.sh"
# ── MC4 a heavier lane frees more per lane: fewer lanes go, the cap widens ──
mc_tick "$(new_cache)" 4 "0 $(mb 1024) $GIB16 host"
expect_eq "MC4 rss 10 MB, 1024 MB short: per lane 512, cap 4 - 2" "2" "$(tk 1 mem_cap)"
expect_eq "MC4 mem_tests_mb is the test tree rss" "10" "$(tk 1 mem_tests_mb)"
LS2_ROOT_RSS_KB=12582912 mc_tick "$(new_cache)" 4 "0 $(mb 1024) $GIB16 host"
expect_eq "MC4 rss 12288 MB: measured" "12288" "$(tk 1 mem_tests_mb)"
expect_eq "MC4 rss 12288 MB over H 4: per lane 3072, one lane covers 1024 MB, cap 3" "3" "$(tk 1 mem_cap)"
LS2_ROOT_RSS_KB=12582912 mc_tick "$(new_cache)" 2 "0 $(mb 4096) $GIB16 host"
expect_eq "MC4 rss 12288 MB over H 2, avail above the reserve: still no cap" "none" "$(tk 1 mem_cap)"
case_ran MC4
case_end

# mc_cap <label> <want> <held> <tests-mb> <avail-mb> <total-kb> — one tick with the test tree
# rss at <tests-mb>, then expect its mem_cap.
mc_cap() {
    LS2_ROOT_RSS_KB="$(mb "$4")" mc_tick "$(new_cache)" "$3" "0 $(mb "$5") $6 host"
    expect_eq "$1" "$2" "$(tk 1 mem_cap)"
}

case_begin "memory-release-per-lane" "bin/lib/test-host-alloc.sh"
# ── MC7 per lane 2048 MB, 2048 MB short: one lane goes (512 MB per lane would take 4) ─
mc_cap "MC7 H 8, rss 16384, avail 7952 of reserve 10000: cap 8 - 1" 7 8 16384 7952 "$MB100K"
mc_cap "MC7 H 4, rss 8192, avail 0 of reserve 2048: cap 4 - 1" 3 4 8192 0 "$GIB16"
case_ran MC7

# ── MC8 the cap equals the lane count that fits once the test tree rss is added back ─
# Rows: H tests_mb avail_mb total_kb reserve_mb; tests_mb = H x per_lane exactly, per_lane >= 512.
MC8_ROWS=("4 8192 0 $GIB16 2048" "6 6144 100 $GIB16 2048" "3 3000 1 $GIB16 2048" "10 30720 5000 $MB100K 10000")
for _r in "${MC8_ROWS[@]}"; do
    read -r _h _ts _av _tt _rs <<< "$_r"
    _per=$(((_ts + _h - 1) / _h))
    _want=$(((_av + _ts - _rs) / _per)); [ "$_want" -ge 1 ] || _want=1
    mc_cap "MC8 H $_h rss $_ts avail $_av reserve $_rs: floor((avail + rss - reserve) / $_per)" \
        "$_want" "$_h" "$_ts" "$_av" "$_tt"
done
# An rss H does not divide: per_lane rounds up (4001 / 4 -> 1001), and the cap follows the
# detail §3 rule H - ceil(short / per_lane), not the add-back form (equal only when H divides).
LS2_ROOT_RSS_KB="$(mb 4001)" mc_tick "$(new_cache)" 4 "0 $(mb 1047) $GIB16 host"
expect_eq "MC8 rss 4001 is measured as is" "4001" "$(tk 1 mem_tests_mb)"
expect_eq "MC8 rss 4001 over H 4: per lane 1001 (not 1000), short 1001: cap 4 - 1" "3" "$(tk 1 mem_cap)"
mc_cap "MC8 rss 4001 over H 4, short 1000: cap 4 - 1" 3 4 4001 1048 "$GIB16"
mc_cap "MC8 rss 4001 over H 4, short 1002 (per lane + 1): cap 4 - 2" 2 4 4001 1046 "$GIB16"
mc_cap "MC8 rss 3001 over H 3 (per lane 1001), short 1001: cap 3 - 1" 2 3 3001 1047 "$GIB16"
mc_cap "MC8 rss 3001 over H 3 (per lane 1001), short 1002: cap 3 - 2" 1 3 3001 1046 "$GIB16"
case_ran MC8

# ── MC9 the ceil boundary at per lane 1024 (H 4, rss 4096, reserve 2048) ────
mc_cap "MC9 short exactly per_lane (1024): one lane goes" 3 4 4096 1024 "$GIB16"
mc_cap "MC9 short per_lane + 1 (1025): two lanes go" 2 4 4096 1023 "$GIB16"
mc_cap "MC9 short per_lane - 1 (1023): one lane goes" 3 4 4096 1025 "$GIB16"
# Per lane 1001 (H 4, rss 4001) against reserve 10000: around per_lane x (H - 2) = 2002 and
# per_lane x (H - 1) = 3003, past which the cap floors at 1.
mc_cap "MC9 per lane 1001, short 2002 = per_lane x (H - 2): cap 2" 2 4 4001 7998 "$MB100K"
mc_cap "MC9 per lane 1001, short 2003: cap 1" 1 4 4001 7997 "$MB100K"
mc_cap "MC9 per lane 1001, short 3002: cap 1" 1 4 4001 6998 "$MB100K"
mc_cap "MC9 per lane 1001, short 3003 = per_lane x (H - 1): cap 1" 1 4 4001 6997 "$MB100K"
mc_cap "MC9 per lane 1001, short 3004: cap 0 floors at 1" 1 4 4001 6996 "$MB100K"
# Above the reserve at per lane 1001 (H 3): no cap however much is over; the pool stays 15.
for _ov in 0 1 1001 3004; do
    LS2_ROOT_RSS_KB="$(mb 3001)" mc_tick "$(new_cache)" 3 "0 $(mb $((2048 + _ov))) $GIB16 host"
    expect_eq "MC9 per lane 1001, $_ov MB over the reserve: no cap" "none" "$(tk 1 mem_cap)"
    expect_eq "MC9 per lane 1001, $_ov MB over the reserve: pool 15" "15" "$(tk 1 pool)"
done
case_ran MC9
case_end

case_begin "memory-release-floor" "bin/lib/test-host-alloc.sh"
# ── MC10 a shortfall of H x per_lane or more still leaves 1 lane ────────────
mc_cap "MC10 short 2048 = H 2 x per lane 1024: cap 1" 1 2 2048 0 "$GIB16"
mc_cap "MC10 short 10000 = 5 x H 2 x per lane 1024: cap 1" 1 2 2048 0 "$MB100K"
case_ran MC10

# ── MC11 a light lane counts as 512 MB; with H 0 per lane is 512 ────────────
mc_cap "MC11 H 4, rss 1024 (256 per lane -> 512), 600 MB short: cap 4 - 2" 2 4 1024 1448 "$GIB16"
LS2_ROOT_RSS_KB="$(mb 1024)" mc_tick "$(new_cache)" 3 "0 $(mb 4096) $GIB16 host"
expect_eq "MC11 H 3, rss 1024 (342 per lane -> 512), 2048 MB over the reserve: no cap" "none" "$(tk 1 mem_cap)"
mc_tick "$(new_cache)" 0 "0 $(mb 3072) $GIB16 host"
expect_eq "MC11 H 0, 1024 MB over: no cap" "none" "$(tk 1 mem_cap)"
expect_eq "MC11 H 0, 1024 MB over: the new run starts at 4 (no spare-lane trim)" "4 15 15 slow-start" "$(trow 1 1)"
LS2_ROOT_RSS_KB="$(mb 2048)" mc_tick "$(new_cache)" 2 "0 $(mb 7048) $GIB16 host"
expect_eq "MC11 H 2, rss 2048 (per lane 1024), 5000 MB over: no cap" "none" "$(tk 1 mem_cap)"
case_ran MC11
case_end

case_begin "memory-unknown" "bin/lib/test-host-alloc.sh"
# ── MC5 no memory lines and none before: no cap ─────────────────────────────
mc_tick "$(new_cache)" 2 "0"
expect_eq "MC5 state ok without memory lines" "ok" "$(tk 1 state)"
expect_eq "MC5 mem_avail_mb unknown" "unknown" "$(tk 1 mem_avail_mb)"
expect_eq "MC5 mem_scope unknown" "unknown" "$(tk 1 mem_scope)"
expect_eq "MC5 mem_cap none" "none" "$(tk 1 mem_cap)"
expect_eq "MC5 the sample carries neither mem_spare_lanes nor held_samples" "" \
    "$(tk 1 mem_spare_lanes)$(tk 1 held_samples)"
case_ran MC5
case_end

case_begin "memory-scope" "bin/lib/test-host-alloc.sh"
# ── MC6 an 8 GiB cgroup: reserve 2048, 3 GiB avail is not short ─────────────
mc_tick "$(new_cache)" 2 "0 $(mb 3072) $(mb 8192) cgroup"
expect_eq "MC6 cgroup: mem_scope" "cgroup" "$(tk 1 mem_scope)"
expect_eq "MC6 cgroup: mem_total_mb is the limit" "8192" "$(tk 1 mem_total_mb)"
expect_eq "MC6 cgroup: reserve max(2048, 819)" "2048" "$(tk 1 mem_reserve_mb)"
expect_eq "MC6 cgroup: no cap" "none" "$(tk 1 mem_cap)"
mc_tick "$(new_cache)" 2 "0 $(mb 10000) $MB100K host"
expect_eq "MC6 100000 MB host: reserve is 10% = 10000" "10000" "$(tk 1 mem_reserve_mb)"
expect_eq "MC6 avail equal to the reserve: no cap" "none" "$(tk 1 mem_cap)"
case_ran MC6
case_end

case_begin "memory-recovery" "bin/lib/test-host-alloc.sh"
# ── MC12 one run, one cache: short (cap 3), then enough memory: cap none, pool 15, +1 per tick ─
# Run 1 keeps holding 4 lanes, so it has used up width 3 and then 4; ssthresh 3 makes it +1.
for _rec in 1 0; do
    MC12C="$(new_cache)"
    al_run "$MC12C" 1; al_lanes "$MC12C" 1 4 1
    al_prev "$MC12C" -- "$(row 1 4 15 15 slow-start)"
    if [ "$_rec" = 1 ]; then _sp2="0 $(mb 8192) $GIB16 host"; else _sp2="0 $(mb 1536) $GIB16 host"; fi
    al_snaps "$MC12C" "$MC12C/snaps" "0 $(mb 1536) $GIB16 host" "$_sp2" "$_sp2"
    al_drv "$MC12C" "$MC12C/snaps" "$ON" -- 'al_tick 1; al_tick 2; al_tick 3'
    expect_eq "MC12 rec=$_rec tick 1: 512 MB short, cap 3" "3" "$(tk 1 mem_cap)"
    expect_eq "MC12 rec=$_rec tick 1: pool 3" "3" "$(tk 1 pool)"
    expect_eq "MC12 rec=$_rec tick 1: cut to 3 by memory-limit" "3 3 3 memory-limit" "$(trow 1 1)"
    if [ "$_rec" = 1 ]; then
        expect_eq "MC12 tick 2: 6144 MB over the reserve, cap back to none" "none" "$(tk 2 mem_cap)"
        expect_eq "MC12 tick 2: pool back to 15" "15" "$(tk 2 pool)"
        expect_eq "MC12 tick 2: cap none after cap 3 allows growth, +1 at ssthresh 3" "4 3 15 slow-start" "$(trow 2 1)"
        expect_eq "MC12 tick 3: still none, grows again by +1" "5 3 15 slow-start" "$(trow 3 1)"
    else
        expect_eq "MC12 control tick 2: still short, cap 3" "3" "$(tk 2 mem_cap)"
        expect_eq "MC12 control tick 2: pool 3" "3" "$(tk 2 pool)"
        expect_eq "MC12 control tick 2: no growth" "3 3 3 memory-limit" "$(trow 2 1)"
        expect_eq "MC12 control tick 3: no growth" "3 3 3 memory-limit" "$(trow 3 1)"
    fi
done
case_ran MC12
case_end

grp_done memory-cases.sh
