#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/cap-drop-cases.sh — CD1-CD5: a row whose run-all per-run
# lane cap falls below its previous cap while its width already fits the new cap. A CPU or memory
# limit (cap < the cap with no CPU or memory reduction) lowers ssthresh to max(2, cap) (CD1, CD2);
# a fall by demand alone keeps it (CD3). A memory cap that holds the width under its cap is
# decided by memory-limit (CD4); with no memory cap it stays slow-start (CD5).

case_begin "cap-drop-ssthresh" "bin/lib/test-host-alloc.sh"
# ── CD1 load scale-in 5 drops the cap 15 -> 10 under a width 4: ssthresh 15 -> 10 ─
CD1C="$(new_cache)"
al_run "$CD1C" 1; al_lanes "$CD1C" 1 4 1
al_prev "$CD1C" external_centicores=500 above=1 -- "$(row 1 4 15 15 slow-start)"
al_snaps "$CD1C" "$CD1C/snaps" "500"
al_drv "$CD1C" "$CD1C/snaps" "$ON" -- 'al_tick 1'
expect_eq "CD1 positive control: scale_in 5" "5" "$(tk 1 scale_in)"
expect_eq "CD1 width 4 <= cap 10: width kept, ssthresh lowered to the cap 10" "4 10 10 slow-start" "$(trow 1 1)"
case_ran CD1

# ── CD2 a memory cap drops the cap 15 -> 3 / 1 under a width that fits: ssthresh max(2, cap) ─
CD2C="$(new_cache)"
al_run "$CD2C" 1; al_lanes "$CD2C" 1 4 1
al_prev "$CD2C" -- "$(row 1 3 15 15 slow-start)"
al_snaps "$CD2C" "$CD2C/snaps" "0 $(mb 1536) $GIB16 host"
al_drv "$CD2C" "$CD2C/snaps" "$ON" -- 'al_tick 1'
expect_eq "CD2 positive control: mem_cap 3" "3" "$(tk 1 mem_cap)"
expect_eq "CD2 width 3 = cap 3: ssthresh 15 -> 3, decided by memory-limit" "3 3 3 memory-limit" "$(trow 1 1)"
CD2D="$(new_cache)"
al_run "$CD2D" 1; al_lanes "$CD2D" 1 4 1
al_prev "$CD2D" -- "$(row 1 1 15 15 slow-start)"
al_snaps "$CD2D" "$CD2D/snaps" "0 $(mb 512) $GIB16 host"
al_drv "$CD2D" "$CD2D/snaps" "$ON" -- 'al_tick 1'
expect_eq "CD2 positive control: mem_cap 1" "1" "$(tk 1 mem_cap)"
expect_eq "CD2 width 1 = cap 1: ssthresh floors at 2" "1 2 1 memory-limit" "$(trow 1 1)"
case_ran CD2

# ── CD3 the cap falls by demand alone: ssthresh is kept ─────────────────────
# Run 1 holds 3 lanes of width 4, so it never grows. (a) a second run arrives (cap 15 -> 8);
# (b) run 1's own demand is 6 (cap 15 -> 6). Mode off: no CPU or memory limit.
CD3C="$(new_cache)"
al_run "$CD3C" 1; al_lanes "$CD3C" 1 3 1; al_run "$CD3C" 2
al_prev "$CD3C" -- "$(row 1 4 15 15 slow-start)"
al_drv "$CD3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "CD3 (a) a second run: cap 15 -> 8 by demand, ssthresh 15 kept" "4 15 8 slow-start" "$(trow 1 1)"
CD3D="$(new_cache)"
al_run "$CD3D" 1 6; al_lanes "$CD3D" 1 3 1
al_prev "$CD3D" -- "$(row 1 4 15 15 slow-start)"
al_drv "$CD3D" "$(new_snaps)" -- 'al_tick 1'
expect_eq "CD3 (b) its own demand 6: cap 15 -> 6 by demand, ssthresh 15 kept" "4 15 6 slow-start" "$(trow 1 1)"
case_ran CD3
case_end

case_begin "cap-drop-decided-by" "bin/lib/test-host-alloc.sh"
# ── CD4 a memory cap 9 stops growth of width 4: decided by memory-limit ─────
# H 10 (test rss 10 MB, so 512 MB per lane), 512 MB short of the reserve 2048: one lane goes.
CD4C="$(new_cache)"
al_run "$CD4C" 1; al_lanes "$CD4C" 1 10 1
al_prev "$CD4C" -- "$(row 1 4 15 15 slow-start)"
al_snaps "$CD4C" "$CD4C/snaps" "0 $(mb 1536) $GIB16 host"
al_drv "$CD4C" "$CD4C/snaps" "$ON" -- 'al_tick 1'
expect_eq "CD4 positive control: mem_cap 9" "9" "$(tk 1 mem_cap)"
expect_eq "CD4 width 4 < cap 9 held by the memory cap: memory-limit, ssthresh 9" "4 9 9 memory-limit" "$(trow 1 1)"
case_ran CD4

# ── CD5 no memory cap and width < cap: slow-start ───────────────────────────
CD5C="$(new_cache)"
al_run "$CD5C" 1; al_lanes "$CD5C" 1 3 1
al_prev "$CD5C" -- "$(row 1 4 15 15 slow-start)"
al_snaps "$CD5C" "$CD5C/snaps" "0 $(mb 8192) $GIB16 host"
al_drv "$CD5C" "$CD5C/snaps" "$ON" -- 'al_tick 1'
expect_eq "CD5 positive control: mem_cap none" "none" "$(tk 1 mem_cap)"
expect_eq "CD5 width 4 < cap 15 without a memory cap: slow-start" "4 15 15 slow-start" "$(trow 1 1)"
case_ran CD5
case_end

grp_done cap-drop-cases.sh
