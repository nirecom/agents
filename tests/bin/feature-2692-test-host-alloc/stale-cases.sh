#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/stale-cases.sh — ST1-ST4: a previous sample that is
# readable as schema 2 but older than three heartbeats (ten driver heartbeats AL_HB). Outline:
# the slow-start state carries over across generations, and on a stale sample a run keeps its
# previous width and does not grow. Every case goes through thl_load_tick on a real sample file.

STALE_AGE=$((10 * AL_HB))
# st_prev <cache> [key=val ...] [-- <row> ...] — the previous sample, STALE_AGE seconds old.
st_prev() { local c="$1"; shift; ls2_write "$c" "$STALE_AGE" "$@"; }

case_begin "stale-sample-carry-over" "bin/lib/test-host-alloc.sh"
# ── ST1 a stale row carries its width and ssthresh over, and never grows ─────
# Run 1 alone with demand 10 (share 10); its stale row says width 8, ssthresh 6.
# (a) holds 4 of width 8, mode off.
ST1A="$(new_cache)"
al_run "$ST1A" 1 10; al_lanes "$ST1A" 1 4 1
st_prev "$ST1A" -- "$(row 1 8 6 10 slow-start)"
al_drv "$ST1A" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST1 (a) the tick rewrote the stale sample as schema 2" "2" "$(tk 1 schema)"
expect_eq "ST1 (a) stale row 8/6, held 4, mode off: keeps width 8 and ssthresh 6" "8 6 10 slow-start" "$(trow 1 1)"
# (b) holds all 8, mode off: a fresh sample would grow it; a stale one does not.
ST1B="$(new_cache)"
al_run "$ST1B" 1 10; al_lanes "$ST1B" 1 8 1
st_prev "$ST1B" -- "$(row 1 8 6 10 slow-start)"
al_drv "$ST1B" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST1 (b) stale row 8/6, held 8, mode off: no growth, stays 8 of ssthresh 6" "8 6 10 slow-start" "$(trow 1 1)"
# (c) holds all 8, mode on with no load: a stale previous sample is never computed against
# (unmeasurable, no memory cap), and the row still does not grow.
ST1C="$(new_cache)"
al_run "$ST1C" 1 10; al_lanes "$ST1C" 1 8 1
st_prev "$ST1C" -- "$(row 1 8 6 10 slow-start)"
al_snaps "$ST1C" "$ST1C/snaps" "0 $(mb 10000) $MB100K host"
al_drv "$ST1C" "$ST1C/snaps" "$ON" -- 'al_tick 1'
expect_eq "ST1 (c) mode on: a stale previous sample gives unmeasurable" "unmeasurable" "$(tk 1 state)"
expect_eq "ST1 (c) mode on: no memory cap" "none" "$(tk 1 mem_cap)"
expect_eq "ST1 (c) stale row 8/6, held 8, mode on: no growth, stays 8 of ssthresh 6" "8 6 10 slow-start" "$(trow 1 1)"
case_ran ST1

# ── ST2 a stale row above the share is cut to it; ssthresh follows the old rule ─
# Run 1 (stale 12/12, held 12) and run 2 (stale 3/6, held 3) share 8/7 of 15. The share equals
# the top share, so ssthresh stays (a stale sample is never measured, so no CPU or memory limit
# can put the share under the top share here).
ST2A="$(new_cache)"
al_run "$ST2A" 1; al_lanes "$ST2A" 1 12 1; al_run "$ST2A" 2; al_lanes "$ST2A" 2 3 13
st_prev "$ST2A" -- "$(row 1 12 12 15 per-run-cap)" "$(row 2 3 6 7 slow-start)"
al_drv "$ST2A" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST2 run 1 stale 12/12 cut to its share 8, ssthresh 12 kept" "8 12 8 per-run-cap" "$(trow 1 1)"
expect_eq "ST2 run 2 stale 3/6 keeps 3 and ssthresh 6" "3 6 7 slow-start" "$(trow 1 2)"
# (b) the takeover round after a stale sample: run 1 holds 11 (lane 12 free), run 2 holds all 3
# of its width, so a fresh sample would grow run 2. Stale: run 1 is cut 12 -> 8, run 2 stays 3.
ST2B="$(new_cache)"
al_run "$ST2B" 1; al_lanes "$ST2B" 1 11 1; al_run "$ST2B" 2; al_lanes "$ST2B" 2 3 13
st_prev "$ST2B" -- "$(row 1 12 12 15 slow-start)" "$(row 2 3 6 7 slow-start)"
al_drv "$ST2B" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST2 (b) stale, takeover: run 1 shrinks 12 -> 8 (the per-run lane cap), ssthresh 12 kept" "8 12 8 per-run-cap" "$(trow 1 1)"
expect_eq "ST2 (b) stale, takeover: run 2 does not grow on this round (3 of ssthresh 6)" "3 6 7 slow-start" "$(trow 1 2)"
# (c) control: the same holdings with a fresh previous sample: run 2 doubles 3 -> 6.
ST2C="$(new_cache)"
al_run "$ST2C" 1; al_lanes "$ST2C" 1 11 1; al_run "$ST2C" 2; al_lanes "$ST2C" 2 3 13
al_prev "$ST2C" -- "$(row 1 12 12 15 slow-start)" "$(row 2 3 6 7 slow-start)"
al_drv "$ST2C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST2 (c) control, fresh: run 1 shrinks 12 -> 8 all the same" "8 12 8 per-run-cap" "$(trow 1 1)"
expect_eq "ST2 (c) control, fresh: run 2 grows 3 -> 6 (the free lane 12 and its 3 used up)" "6 6 7 slow-start" "$(trow 1 2)"
case_ran ST2
case_end

case_begin "stale-sample-controls" "bin/lib/test-host-alloc.sh"
# ── ST3 controls: a fresh row grows; an unreadable sample means a new run ────
# (a) fresh (one heartbeat old) row 8/6, held 8, mode off: +1 to 9.
ST3A="$(new_cache)"
al_run "$ST3A" 1 10; al_lanes "$ST3A" 1 8 1
al_prev "$ST3A" -- "$(row 1 8 6 10 slow-start)"
al_drv "$ST3A" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (a) control, fresh row 8/6, held 8: grows to 9" "9 6 10 slow-start" "$(trow 1 1)"
# (b) no sample at all, held 4: the new-run start width 4, ssthresh top 15.
ST3B="$(new_cache)"
al_run "$ST3B" 1 10; al_lanes "$ST3B" 1 4 1
al_drv "$ST3B" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (b) no sample: a new run, 4 of ssthresh 15" "4 15 10 slow-start" "$(trow 1 1)"
# st3_gen1 <cache> — a run of code that predates #2692 writes a generation-1 sample over load/sample.
st3_gen1() {
    printf 'schema=1\nmeasured_at=%s\nstate=ok\nhost_counter=system\nexternal_centicores=0\nscale_in=0\nabove=0\nbelow=0\n' \
        "$(($(now_epoch) - 3))" > "$1/load/sample"
}
# st3_runs_extra <cache> — every entry under runs/ other than the presence records run.*.
st3_runs_extra() {
    local e out=""
    for e in "$1"/runs/*; do
        [[ -e $e ]] || continue
        [[ ${e##*/} == run.* ]] || out+="${e##*/} "
    done
    printf '%s' "${out% }"
}
# (c) a generation-2 tick gives run 1 the row 8/6 (it holds lanes 1-4); then code that predates
# #2692 writes a generation-1 sample over it. On the next tick run 1 restarts from the 4 lanes it
# holds now: width 4 and ssthresh 4, with no growth on that tick.
ST3C="$(new_cache)"
al_run "$ST3C" 1 10; al_lanes "$ST3C" 1 4 1
al_prev "$ST3C" -- "$(row 1 8 6 10 slow-start)"
al_drv "$ST3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (c) setup: the generation-2 tick writes run 1's row 8/6" "8 6 10 slow-start" "$(trow 1 1)"
st3_gen1 "$ST3C"
al_drv "$ST3C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (c) after a generation-1 sample, run 1 holding 4 lanes: width 4, ssthresh 4, no growth" "4 4 10 slow-start" "$(trow 1 1)"
expect_eq "ST3 (c) the allocation is kept only in load/sample: runs/ holds nothing but run.* (no sample.2)" "" "$(st3_runs_extra "$ST3C")"
# (d) a stale schema-2 sample that is malformed (an unknown key) carries no row: a new run.
ST3D="$(new_cache)"
al_run "$ST3D" 1 10; al_lanes "$ST3D" 1 4 1
st_prev "$ST3D" -- "$(row 1 8 6 10 slow-start)"
printf 'bogus=1\n' >> "$ST3D/load/sample"
al_drv "$ST3D" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (d) a broken stale sample: a new run, 4 of ssthresh 15" "4 15 10 slow-start" "$(trow 1 1)"
# (e) as (c), but run 1 holds no lane: after the generation-1 sample it is a newly arrived run,
# as with no sample at all (start width 4 within 15 free lanes, ssthresh top 15).
ST3E="$(new_cache)"
al_run "$ST3E" 1 10
al_prev "$ST3E" -- "$(row 1 8 6 10 slow-start)"
al_drv "$ST3E" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (e) setup: the generation-2 tick writes run 1's row 8/6" "8 6 10 slow-start" "$(trow 1 1)"
st3_gen1 "$ST3E"
al_drv "$ST3E" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST3 (e) after a generation-1 sample, run 1 holding no lane: a new run, 4 of ssthresh 15" "4 15 10 slow-start" "$(trow 1 1)"
expect_eq "ST3 (e) runs/ holds nothing but run.* (no sample.2)" "" "$(st3_runs_extra "$ST3E")"
case_ran ST3

# ── ST4 a run with no row in the stale sample is a new run within the free lanes ─
# Run 1 (stale 12/12, held 12) and run 2 (no row): 3 lanes free.
ST4C="$(new_cache)"
al_run "$ST4C" 1; al_lanes "$ST4C" 1 12 1; al_run "$ST4C" 2
st_prev "$ST4C" -- "$(row 1 12 12 15 per-run-cap)"
al_drv "$ST4C" "$(new_snaps)" -- 'al_tick 1'
expect_eq "ST4 run 1 stale 12/12 cut to its share 8, ssthresh 12 kept" "8 12 8 per-run-cap" "$(trow 1 1)"
expect_eq "ST4 run 2 without a row starts at the 3 free lanes of share 7" "3 15 7 slow-start" "$(trow 1 2)"
case_ran ST4
case_end

grp_done stale-cases.sh
