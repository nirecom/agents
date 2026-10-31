#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/unmeasured-cases.sh — UM1-UM7: what a tick does when a
# side cannot be measured. There is no hold: an unmeasurable CPU reading resets the hysteresis
# (scale_in / above / below 0) and stops growth on that sample only; an unknown memory reading
# is no cap on that sample (the previous cap is not kept). No held_samples key is ever written.
# Mode on unless noted.

# Previous-sample header fields of a 512 MB short host (cap 3 over H 3).
UM_MEM="mem_avail_mb=1536 mem_total_mb=16384 mem_reserve_mb=2048 mem_scope=host mem_cap=3"

case_begin "unmeasured-cpu" "bin/lib/test-host-alloc.sh"
# ── UM1 the probe fails after scale-in 3: the hysteresis resets, growth stops ─
UM1C="$(new_cache)"
al_run "$UM1C" 1; al_lanes "$UM1C" 1 4 1; al_run "$UM1C" 2
al_prev "$UM1C" external_centicores=300 scale_in=3 above=2 pool=12 -- "$(row 1 4 15 12 slow-start)"
al_snaps "$UM1C" "$UM1C/snaps" FAIL
al_drv "$UM1C" "$UM1C/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM1 the probe failed: unmeasurable" "unmeasurable" "$(tk 1 state)"
expect_eq "UM1 scale_in / above / below reset to 0" "0 0 0" "$(tk 1 scale_in) $(tk 1 above) $(tk 1 below)"
expect_eq "UM1 pool back to 15 (no scale-in kept)" "15" "$(tk 1 pool)"
expect_eq "UM1 the sample carries no held_samples key" "" "$(tk 1 held_samples)"
expect_eq "UM1 run 1 does not grow on an unmeasurable sample; share 8" "4 15 8 slow-start" "$(trow 1 1)"
expect_eq "UM1 the new run 2 starts at 4 of share 7" "4 15 7 slow-start" "$(trow 1 2)"
# A previous sample that was itself unmeasurable resets the same way (no count of failures).
UM1D="$(new_cache)"
al_run "$UM1D" 1; al_lanes "$UM1D" 1 3 1
al_prev "$UM1D" state=unmeasurable external_centicores=300 scale_in=3 above=2 pool=12 -- "$(row 1 3 15 12 slow-start)"
al_snaps "$UM1D" "$UM1D/snaps" FAIL
al_drv "$UM1D" "$UM1D/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM1 second failure: scale_in / above 0" "0 0" "$(tk 1 scale_in) $(tk 1 above)"
expect_eq "UM1 second failure: pool 15" "15" "$(tk 1 pool)"
expect_eq "UM1 second failure: the run keeps 3, no growth" "3 15 15 slow-start" "$(trow 1 1)"
case_ran UM1

# ── UM2 the sample after an unmeasurable one is measured: growth resumes ────
UM2C="$(new_cache)"
al_run "$UM2C" 1; al_lanes "$UM2C" 1 4 1
al_prev "$UM2C" state=unmeasurable -- "$(row 1 4 15 15 slow-start)"
al_snaps "$UM2C" "$UM2C/snaps" "0"
al_drv "$UM2C" "$UM2C/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM2 measured again: state ok" "ok" "$(tk 1 state)"
expect_eq "UM2 measured again: scale_in 0" "0" "$(tk 1 scale_in)"
expect_eq "UM2 measured, previous sample fresh: doubles 4 -> 8" "8 15 15 slow-start" "$(trow 1 1)"
case_ran UM2

# ── UM4 any number of failures: each stops growth, none releases a hold ─────
# Five failures in a row, then one measured sample: the width stays 4 on every failure (no
# hold count that ends after 3 and lets growth through) and doubles on the measured one.
UM4C="$(new_cache)"
al_run "$UM4C" 1; al_lanes "$UM4C" 1 4 1
al_snaps "$UM4C" "$UM4C/snaps" FAIL FAIL FAIL FAIL FAIL "0"
al_drv "$UM4C" "$UM4C/snaps" "$ON" -- 'for i in 1 2 3 4 5 6; do al_tick "$i"; done'
UM4_W=""; UM4_S=""
for _i in 1 2 3 4 5 6; do
    _r="$(trow "$_i" 1)"; UM4_W="$UM4_W ${_r%% *}"; UM4_S="$UM4_S $(tk "$_i" scale_in)/$(tk "$_i" pool)"
done
expect_eq "UM4 widths over 5 failures then 1 measured sample" " 4 4 4 4 4 8" "$UM4_W"
expect_eq "UM4 scale_in / pool on every tick" " 0/15 0/15 0/15 0/15 0/15 0/15" "$UM4_S"
expect_eq "UM4 tick 6 is measured" "ok" "$(tk 6 state)"
case_ran UM4
case_end

case_begin "unmeasured-memory" "bin/lib/test-host-alloc.sh"
# ── UM3 memory measured before, unknown now: no cap this sample (not kept) ──
UM3C="$(new_cache)"
al_run "$UM3C" 1; al_lanes "$UM3C" 1 3 1
# shellcheck disable=SC2086
al_prev "$UM3C" $UM_MEM pool=3 -- "$(row 1 3 3 3 memory-limit)"
al_snaps "$UM3C" "$UM3C/snaps" "0"
al_drv "$UM3C" "$UM3C/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM3 CPU measured: state ok" "ok" "$(tk 1 state)"
expect_eq "UM3 memory unknown now: mem_avail_mb unknown" "unknown" "$(tk 1 mem_avail_mb)"
expect_eq "UM3 the previous mem_cap 3 is not kept: none" "none" "$(tk 1 mem_cap)"
expect_eq "UM3 pool back to 15" "15" "$(tk 1 pool)"
expect_eq "UM3 the sample carries no held_samples key" "" "$(tk 1 held_samples)"
expect_eq "UM3 no cap, lanes used up: +1 at ssthresh 3" "4 3 15 slow-start" "$(trow 1 1)"
case_ran UM3

# ── UM5 memory unknown while CPU is measured: the hysteresis carries on ─────
UM5C="$(new_cache)"
al_run "$UM5C" 1; al_lanes "$UM5C" 1 3 1
# shellcheck disable=SC2086
al_prev "$UM5C" external_centicores=300 above=1 $UM_MEM pool=3 -- "$(row 1 3 3 3 memory-limit)"
al_snaps "$UM5C" "$UM5C/snaps" "300"
al_drv "$UM5C" "$UM5C/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM5 CPU measured: state ok" "ok" "$(tk 1 state)"
expect_eq "UM5 above 1 -> 2" "2" "$(tk 1 above)"
expect_eq "UM5 scale-in engages at 3" "3" "$(tk 1 scale_in)"
expect_eq "UM5 memory unknown: mem_cap none (cap 3 not kept)" "none" "$(tk 1 mem_cap)"
expect_eq "UM5 pool is the CPU pool 15 - 3" "12" "$(tk 1 pool)"
expect_eq "UM5 scale-in 3 stops growth: stays 3 of share 12" "3 3 12 slow-start" "$(trow 1 1)"
case_ran UM5
case_end

case_begin "unmeasured-no-previous" "bin/lib/test-host-alloc.sh"
# ── UM6 no previous sample and a failure ────────────────────────────────────
UM6C="$(new_cache)"
al_run "$UM6C" 1; al_lanes "$UM6C" 1 4 1
al_snaps "$UM6C" "$UM6C/snaps" FAIL
al_drv "$UM6C" "$UM6C/snaps" "$ON" -- 'al_tick 1'
expect_eq "UM6 unmeasurable" "unmeasurable" "$(tk 1 state)"
expect_eq "UM6 scale_in 0" "0" "$(tk 1 scale_in)"
expect_eq "UM6 mem_cap none" "none" "$(tk 1 mem_cap)"
expect_eq "UM6 the sample carries no held_samples key" "" "$(tk 1 held_samples)"
expect_eq "UM6 the row is still written" "4 15 15 slow-start" "$(trow 1 1)"
case_ran UM6

# ── UM7 mode off never measures ─────────────────────────────────────────────
UM7C="$(new_cache)"
UM7S="$(new_snaps)"
al_run "$UM7C" 1; al_lanes "$UM7C" 1 3 1
# shellcheck disable=SC2086
al_prev "$UM7C" scale_in=3 above=2 $UM_MEM pool=3 -- "$(row 1 3 3 3 memory-limit)"
al_drv "$UM7C" "$UM7S" -- 'al_tick 1'
expect_eq "UM7 mode off: state off" "off" "$(tk 1 state)"
expect_eq "UM7 mode off: scale_in 0" "0" "$(tk 1 scale_in)"
expect_eq "UM7 mode off: mem_cap none" "none" "$(tk 1 mem_cap)"
expect_eq "UM7 mode off: pool 15" "15" "$(tk 1 pool)"
expect_eq "UM7 mode off: the sample carries no held_samples key" "" "$(tk 1 held_samples)"
expect_eq "UM7 mode off: the probe never runs" "0" "$(probe_calls "$UM7S")"
case_ran UM7
case_end

grp_done unmeasured-cases.sh
