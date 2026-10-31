#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/slow-start-cases.sh — SS1-SS11: RFC 5681 growth of a
# run's width (double below ssthresh, +1 at or above it) and every condition that stops it
# (lanes not used up, no free lane, unmeasurable, any scale-in, a memory cap), shrink to a
# smaller share and decided_by. Mode off unless noted.

case_begin "slow-start-growth" "bin/lib/test-host-alloc.sh"
# ── SS1 a lone run that uses its lanes: 4 -> 8 -> 15 over three ticks ───────
SS1C="$(new_cache)"
al_run "$SS1C" 1
al_drv "$SS1C" "$(new_snaps)" "T1=$(tok 1)" -- 'al_tick 1; al_fill "$T1"; al_tick 2; al_fill "$T1"; al_tick 3'
expect_eq "SS1 tick 1: start at 4" "4 15 15 slow-start" "$(trow 1 1)"
expect_eq "SS1 tick 2: doubled to 8" "8 15 15 slow-start" "$(trow 2 1)"
expect_eq "SS1 tick 3: doubled, capped at the share 15" "15 15 15 per-run-cap" "$(trow 3 1)"
case_ran SS1

# ── SS2 at or above ssthresh: +1 per tick ───────────────────────────────────
SS2C="$(new_cache)"
al_run "$SS2C" 1; al_lanes "$SS2C" 1 6 1
al_prev "$SS2C" -- "$(row 1 6 6 15 slow-start)"
al_drv "$SS2C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS2 width 6 = ssthresh 6: +1, not doubled" "7 6 15 slow-start" "$(trow 1 1)"
case_ran SS2
case_end

case_begin "slow-start-stops" "bin/lib/test-host-alloc.sh"
# ── SS3 a run holding fewer lanes than its width does not grow ──────────────
SS3C="$(new_cache)"
al_run "$SS3C" 1; al_lanes "$SS3C" 1 3 1
al_prev "$SS3C" -- "$(row 1 4 15 15 slow-start)"
al_drv "$SS3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS3 held 3 under width 4: stays 4" "4 15 15 slow-start" "$(trow 1 1)"
case_ran SS3

# ── SS4 no free lane: no growth; one free lane: growth resumes ──────────────
SS4C="$(new_cache)"
al_run "$SS4C" 1; al_lanes "$SS4C" 1 4 1; al_run "$SS4C" 2; al_lanes "$SS4C" 2 11 5
al_prev "$SS4C" -- "$(row 1 4 15 8 slow-start)" "$(row 2 11 15 7 slow-start)"
al_drv "$SS4C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS4 all 15 lanes held: run 1 stays 4" "4 15 8 slow-start" "$(trow 1 1)"
expect_eq "SS4 run 2 above its share 7 is cut to it" "7 15 7 per-run-cap" "$(trow 1 2)"
SS4D="$(new_cache)"
al_run "$SS4D" 1; al_lanes "$SS4D" 1 4 1; al_run "$SS4D" 2; al_lanes "$SS4D" 2 10 5
al_prev "$SS4D" -- "$(row 1 4 15 8 slow-start)" "$(row 2 10 15 7 slow-start)"
al_drv "$SS4D" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS4 control, one lane free: run 1 grows to its share 8" "8 15 8 per-run-cap" "$(trow 1 1)"
expect_eq "SS4 control: run 2 cut to 7" "7 15 7 per-run-cap" "$(trow 1 2)"
case_ran SS4

# ── SS5 mode on, the probe fails: unmeasurable stops growth (no hold) ───────
SS5C="$(new_cache)"
al_run "$SS5C" 1; al_lanes "$SS5C" 1 4 1
al_prev "$SS5C" -- "$(row 1 4 15 15 slow-start)"
al_snaps "$SS5C" "$SS5C/snaps" FAIL
al_drv "$SS5C" "$SS5C/snaps" "$ON" -- 'al_tick 1'
expect_eq "SS5 unmeasurable: state" "unmeasurable" "$(tk 1 state)"
expect_eq "SS5 unmeasurable: scale_in 0 (the hysteresis resets)" "0" "$(tk 1 scale_in)"
expect_eq "SS5 the sample carries no held_samples key" "" "$(tk 1 held_samples)"
expect_eq "SS5 unmeasurable: no growth, stays 4" "4 15 15 slow-start" "$(trow 1 1)"
case_ran SS5

# ── SS6 mode on, any scale-in stops growth: rising 1 -> 3, and a steady 1 ───
# Growth needs this sample's scale-in to be 0; a steady scale-in is still a CPU limit.
for _ext in 300 150; do
    SS6C="$(new_cache)"
    al_run "$SS6C" 1; al_lanes "$SS6C" 1 4 1
    al_prev "$SS6C" external_centicores=150 scale_in=1 above=2 pool=14 -- "$(row 1 4 15 14 slow-start)"
    al_snaps "$SS6C" "$SS6C/snaps" "$_ext"
    al_drv "$SS6C" "$SS6C/snaps" "$ON" -- 'al_tick 1'
    if [ "$_ext" = 300 ]; then
        expect_eq "SS6 ext 300: scale_in 3" "3" "$(tk 1 scale_in)"
        expect_eq "SS6 ext 300: scale-in rose, stays 4 of share 12, ssthresh lowered to the cap 12" "4 12 12 slow-start" "$(trow 1 1)"
    else
        expect_eq "SS6 ext 150: scale_in stays 1" "1" "$(tk 1 scale_in)"
        expect_eq "SS6 ext 150: a steady scale-in 1 still stops growth, stays 4 of share 14" "4 15 14 slow-start" "$(trow 1 1)"
    fi
done
case_ran SS6

# ── SS7 mode on, memory: no cap grows in full; a cap stops growth ───────────
# There is no spare-lane estimate: free memory at or above the reserve is no cap at all, so
# growth is not trimmed by it; a memory cap (avail under the reserve) stops growth.
for _av in 10000 10512; do
    SS7C="$(new_cache)"
    al_run "$SS7C" 1; al_lanes "$SS7C" 1 4 1
    al_prev "$SS7C" -- "$(row 1 4 15 15 slow-start)"
    al_snaps "$SS7C" "$SS7C/snaps" "0 $(mb "$_av") $MB100K host"
    al_drv "$SS7C" "$SS7C/snaps" "$ON" -- 'al_tick 1'
    expect_eq "SS7 avail $_av MB, reserve 10000: mem_cap none" "none" "$(tk 1 mem_cap)"
    expect_eq "SS7 avail $_av MB: no spare trim, doubles 4 -> 8" "8 15 15 slow-start" "$(trow 1 1)"
    expect_eq "SS7 the sample carries no mem_spare_lanes key" "" "$(tk 1 mem_spare_lanes)"
done
# H 6 (two of them spare under the width 4): avail 1536 under the reserve 2048 caps at 5, which
# is still above the width 4 — the cap alone stops growth.
SS7D="$(new_cache)"
al_run "$SS7D" 1; al_lanes "$SS7D" 1 6 1
al_prev "$SS7D" -- "$(row 1 4 15 15 slow-start)"
al_snaps "$SS7D" "$SS7D/snaps" "0 $(mb 1536) $GIB16 host"
al_drv "$SS7D" "$SS7D/snaps" "$ON" -- 'al_tick 1'
expect_eq "SS7 H 6, 512 MB short at 512 per lane: mem_cap 5" "5" "$(tk 1 mem_cap)"
expect_eq "SS7 a memory cap stops growth: stays 4 of share 5, ssthresh 5, decided by memory-limit" "4 5 5 memory-limit" "$(trow 1 1)"
case_ran SS7
case_end

case_begin "slow-start-shrink" "bin/lib/test-host-alloc.sh"
# ── SS8 mode on, scale-in 5 cuts 12 -> 10 (cpu, ssthresh 10); then +1 ───────
SS8C="$(new_cache)"
al_run "$SS8C" 1; al_lanes "$SS8C" 1 12 1
al_prev "$SS8C" external_centicores=500 above=1 -- "$(row 1 12 15 15 slow-start)"
al_snaps "$SS8C" "$SS8C/snaps" "500"
al_drv "$SS8C" "$SS8C/snaps" "$ON" -- 'al_tick 1'
expect_eq "SS8 second sample above 1 core: scale_in 5" "5" "$(tk 1 scale_in)"
expect_eq "SS8 cut to the CPU-limited share, decided by cpu-load-limit" "10 10 10 cpu-load-limit" "$(trow 1 1)"
SS8D="$(new_cache)"
al_run "$SS8D" 1; al_lanes "$SS8D" 1 10 1
al_prev "$SS8D" -- "$(row 1 10 10 10 cpu-load-limit)"
al_snaps "$SS8D" "$SS8D/snaps" "0"
al_drv "$SS8D" "$SS8D/snaps" "$ON" -- 'al_tick 1'
expect_eq "SS8 load gone: width 10 = ssthresh 10 grows by +1" "11 10 15 slow-start" "$(trow 1 1)"
case_ran SS8

# ── SS9 a second run arrives: the first is cut to its share 8 ───────────────
SS9C="$(new_cache)"
al_run "$SS9C" 1; al_lanes "$SS9C" 1 12 1; al_run "$SS9C" 2
al_prev "$SS9C" -- "$(row 1 12 15 15 slow-start)"
al_drv "$SS9C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS9 run 1 cut 12 -> 8 (its share, not a load limit)" "8 15 8 per-run-cap" "$(trow 1 1)"
expect_eq "SS9 run 2 starts at the 3 free lanes of share 7" "3 15 7 slow-start" "$(trow 1 2)"
case_ran SS9

# ── SS10 mode on, the CPU scale-in cap and the memory cap bind in one sample ───
# Runs 1/2 hold 8/7 lanes (H 15, shares 8/7 of top 15); test memory 10 MB, so 512 MB per lane.
# ss10 <label> <ext> <avail_mb> <total_kb> <scale> <cap> <pool> <row1> <row2>
ss10() {
    SS10C="$(new_cache)"
    al_run "$SS10C" 1; al_lanes "$SS10C" 1 8 1; al_run "$SS10C" 2; al_lanes "$SS10C" 2 7 9
    al_prev "$SS10C" "external_centicores=$2" above=1 -- "$(row 1 8 15 8 per-run-cap)" "$(row 2 7 15 7 per-run-cap)"
    al_snaps "$SS10C" "$SS10C/snaps" "$2 $(mb "$3") $4 host"
    al_drv "$SS10C" "$SS10C/snaps" "$ON" -- 'al_tick 1'
    expect_eq "SS10 $1: scale_in $5" "$5" "$(tk 1 scale_in)"
    expect_eq "SS10 $1: mem_cap $6" "$6" "$(tk 1 mem_cap)"
    expect_eq "SS10 $1: pool $7" "$7" "$(tk 1 pool)"
    expect_eq "SS10 $1: run 1 cut, ssthresh to its new share" "$8" "$(trow 1 1)"
    expect_eq "SS10 $1: run 2 cut, ssthresh to its new share" "$9" "$(trow 1 2)"
    expect_eq "SS10 $1: the widths fit the pool" "$7" "$(wsum 1)"
}
# (a) CPU tighter: scale-in 6 -> CPU pool 9; 548 MB free of reserve 2048 (16 GiB) -> 3 lanes
# released, cap 12. Shares 5/4 of pool 9, decided by cpu-load-limit.
ss10 "(a) cpu tighter" 600 548 "$GIB16" 6 12 9 "5 5 5 cpu-load-limit" "4 4 4 cpu-load-limit"
# (b) memory tighter: scale-in 5 -> CPU pool 10; 4000 MB free of reserve 10000 -> 12 released,
# cap 3. Shares 2/1; ssthresh floors at 2 for run 2.
ss10 "(b) memory tighter" 500 4000 "$MB100K" 5 3 3 "2 2 2 memory-limit" "1 2 1 memory-limit"
# (c) equal: scale-in 5 -> CPU pool 10; 7500 MB free of reserve 10000 -> 5 released, cap 10.
# The source's tie rule is `cap <= cpupool` -> memory-limit: on a tie decided_by says memory-limit.
ss10 "(c) equal, the tie goes to memory-limit" 500 7500 "$MB100K" 5 10 10 "5 5 5 memory-limit" "5 5 5 memory-limit"
case_ran SS10
case_end

case_begin "slow-start-new-run-free-lanes" "bin/lib/test-host-alloc.sh"
# ── SS11 a new run's initial width: min(4, share, held + free host lanes) ─────
# Outline: the initial width 4 never exceeds the share, and a new run never exceeds the free
# host lanes; new runs in one sample take the free lanes in presence order. Run 1 is old (it
# has a row) and holds lanes from lane 1 up; mode off, pool 15.
# (a) run 1 holds 13: 2 lanes free; run 2 (share 7) starts at 2, not 4.
SS11A="$(new_cache)"
al_run "$SS11A" 1; al_lanes "$SS11A" 1 13 1; al_run "$SS11A" 2
al_prev "$SS11A" -- "$(row 1 13 15 15 per-run-cap)"
al_drv "$SS11A" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS11 (a) 2 free lanes: the new run 2 starts at 2 of share 7" "2 15 7 slow-start" "$(trow 1 2)"
# (b) run 1 holds 12: 3 lanes free; runs 2 and 3 (share 5 each) are new.
SS11B="$(new_cache)"
al_run "$SS11B" 1; al_lanes "$SS11B" 1 12 1; al_run "$SS11B" 2; al_run "$SS11B" 3
al_prev "$SS11B" -- "$(row 1 12 15 15 per-run-cap)"
al_drv "$SS11B" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS11 (b) 3 free lanes: the earlier new run 2 takes 3 of share 5" "3 15 5 slow-start" "$(trow 1 2)"
expect_eq "SS11 (b) the later new run 3 gets the 0 lanes left" "0 15 5 slow-start" "$(trow 1 3)"
SS11_W2="$(trow 1 2 | cut -d' ' -f1)"; SS11_W3="$(trow 1 3 | cut -d' ' -f1)"
SS11_SUM=-1
[[ $SS11_W2 =~ ^[0-9]+$ && $SS11_W3 =~ ^[0-9]+$ ]] && SS11_SUM=$((SS11_W2 + SS11_W3))
if [ "$SS11_SUM" -ge 0 ] && [ "$SS11_SUM" -le 3 ]; then pass "SS11 (b) the new runs' widths sum to $SS11_SUM <= 3 free lanes"
else fail "SS11 (b) the new runs' widths exceed the 3 free lanes" "sum=$SS11_SUM out=$(printf '%q' "$OUT")"; fi
# (c) control: run 1 holds 4, 11 lanes free: the new run 2 starts at 4.
SS11C="$(new_cache)"
al_run "$SS11C" 1; al_lanes "$SS11C" 1 4 1; al_run "$SS11C" 2
al_prev "$SS11C" -- "$(row 1 4 15 15 per-run-cap)"
al_drv "$SS11C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "SS11 (c) control, 11 free lanes: the new run 2 starts at 4 of share 7" "4 15 7 slow-start" "$(trow 1 2)"
case_ran SS11
case_end

grp_done slow-start-cases.sh
