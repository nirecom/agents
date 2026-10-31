#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/alloc-cases.sh — AL1-AL7: the rows the claim holder
# writes for every run (run-all per-run lane cap, demand cap, n > pool, stale presence, a new run's start,
# no memory trim on growth or start width, an outdated previous sample). Mode off unless noted.

case_begin "alloc-per-run-cap" "bin/lib/test-host-alloc.sh"
# ── AL1 every run gets a row; per-run lane caps 8 7 and 4 4 4 3 of pool 15
AL1C="$(new_cache)"
al_run "$AL1C" 1; al_run "$AL1C" 2
al_drv "$AL1C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL1 two runs: runs=2" "2" "$(tk 1 runs)"
expect_eq "AL1 mode off: pool = 16 - 1" "15" "$(tk 1 pool)"
expect_eq "AL1 two runs: the earlier starts at 4 of share 8" "4 15 8 slow-start" "$(trow 1 1)"
expect_eq "AL1 two runs: the later starts at 4 of share 7" "4 15 7 slow-start" "$(trow 1 2)"
AL1D="$(new_cache)"
for _n in 1 2 3 4; do al_run "$AL1D" "$_n"; done
al_drv "$AL1D" "$(new_snaps)" -- 'al_tick 1'
for _n in 1 2 3; do
    expect_eq "AL1 four runs: run $_n gets its share 4" "4 15 4 per-run-cap" "$(trow 1 "$_n")"
done
expect_eq "AL1 four runs: run 4 gets its share 3" "3 15 3 per-run-cap" "$(trow 1 4)"
expect_eq "AL1 four runs: the widths sum to the pool" "15" "$(wsum 1)"
case_ran AL1
case_end

case_begin "alloc-demand" "bin/lib/test-host-alloc.sh"
# ── AL2 a run of demand 3 gets 3; the other run's share is the rest ─────────
AL2C="$(new_cache)"
al_run "$AL2C" 1 3; al_run "$AL2C" 2
al_drv "$AL2C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL2 demand 3: width 3 = its share" "3 15 3 per-run-cap" "$(trow 1 1)"
expect_eq "AL2 the other run: share 12, starts at 4" "4 15 12 slow-start" "$(trow 1 2)"
case_ran AL2

# ── AL3 more runs than the pool: the last run's row is 0 ────────────────────
AL3C="$(new_cache)"
for _n in 1 2 3; do al_run "$AL3C" "$_n" 1000 3; done
al_drv "$AL3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL3 base 3: pool 2" "2" "$(tk 1 pool)"
expect_eq "AL3 run 1: 1 of pool 2" "1 2 1 per-run-cap" "$(trow 1 1)"
expect_eq "AL3 run 2: 1 of pool 2" "1 2 1 per-run-cap" "$(trow 1 2)"
expect_eq "AL3 run 3: width 0" "0 2 0 per-run-cap" "$(trow 1 3)"
case_ran AL3
case_end

case_begin "alloc-presence" "bin/lib/test-host-alloc.sh"
# ── AL4 a dead run's presence record gets no row and is reclaimed ───────────
AL4C="$(new_cache)"
bash -c 'exit 0' &
_dead=$!
wait "$_dead" 2>/dev/null
al_run "$AL4C" 1 1000 16 "$_dead"; al_run "$AL4C" 2
al_drv "$AL4C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL4 only the live run counts" "1" "$(tk 1 runs)"
expect_eq "AL4 the dead run has no row" "" "$(trow 1 1)"
expect_eq "AL4 the live run alone: share 15" "4 15 15 slow-start" "$(trow 1 2)"
if [ -d "$AL4C/runs/run.$(tok 1)" ]; then
    fail "AL4 the dead run's presence record is reclaimed" "runs/run.$(tok 1) still exists"
else
    pass "AL4 the dead run's presence record is reclaimed"
fi
case_ran AL4

# ── AL5 a new run already holding 6 lanes keeps them ────────────────────────
AL5C="$(new_cache)"
al_run "$AL5C" 1; al_lanes "$AL5C" 1 6 1
al_drv "$AL5C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL5 no previous row: width max(held 6, 4)" "6 15 15 slow-start" "$(trow 1 1)"
case_ran AL5

# ── AL7 an old previous row: the run keeps its width and threshold, no growth ─
AL7C="$(new_cache)"
al_run "$AL7C" 1; al_lanes "$AL7C" 1 6 1
ls2_write "$AL7C" $((15 * AL_HB)) -- "$(row 1 10 15 15 slow-start)"
al_drv "$AL7C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "AL7 previous row 15 heartbeats old: keeps width 10 and threshold 15, no growth" "10 15 15 slow-start" "$(trow 1 1)"
case_ran AL7
case_end

case_begin "alloc-no-memory-trim" "bin/lib/test-host-alloc.sh"
# ── AL6 free memory above the reserve trims nothing: run 1 doubles, run 2 starts at 4 ─
# 4608 MB free over the reserve 2048 is no cap; there is no spare-lane budget that the
# earlier run spends first.
AL6C="$(new_cache)"
al_run "$AL6C" 1; al_lanes "$AL6C" 1 4 1; al_run "$AL6C" 2
al_prev "$AL6C" -- "$(row 1 4 15 15 slow-start)"
al_snaps "$AL6C" "$AL6C/snaps" "0 $(mb 4608) $GIB16 host"
al_drv "$AL6C" "$AL6C/snaps" "$ON" -- 'al_tick 1'
expect_eq "AL6 no memory cap" "none" "$(tk 1 mem_cap)"
expect_eq "AL6 run 1 doubles 4 -> 8 = its share" "8 15 8 per-run-cap" "$(trow 1 1)"
expect_eq "AL6 run 2 (new) starts at 4 of share 7, untrimmed" "4 15 7 slow-start" "$(trow 1 2)"
case_ran AL6
case_end

grp_done alloc-cases.sh
