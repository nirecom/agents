#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/sampler-cases.sh — the sampler (thl_load_tick), the
# hysteresis over the load above the reserved cores, its reset on an unmeasurable sample, the
# reader (thl_load_scale_in) and the pool it shrinks: LS1-LS7, LS12, LS14, LS15, LS17.
# Every sampler case has a live run of max jobs per host 12 on 12 CPUs (0 reserved cores)
# unless noted.

case_begin "load-sampler-hysteresis" "bin/lib/test-host-load.sh"

# ── LS1 I/O-bound own tests + 4 cores of external load ─────────────────────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400 400
load_drv "$C" "$S" -- 'ls_ticks 3'
assert_eq "LS1 driver loads the load lib (rc 0)" "0" "$RC"
assert_near "LS1 external_centicores ~400 on the first measured tick" 400 "$(tick_field "$OUT" tick2 ext)"
assert_eq "LS1 scale_in 4 on the second consecutive sample above the engage threshold" "0 0 4" "$(scales "$OUT")"
assert_eq "LS1 12 CPUs, base 12: reserved_cores 0" "0" "$(tick_field "$OUT" tick3 res)"
assert_eq "LS1 base 12: the sample's pool is 11 - load scale-in 4 = 7" "7" "$(tick_field "$OUT" tick3 pool)"
case_ran LS1

# ── LS2 CPU-heavy own tests only: their descendants are agents internal ─────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" ownheavy 0 0 0 0
load_drv "$C" "$S" -- 'ls_ticks 5'
assert_near "LS2 8 cores of own descendants are not external load" 0 "$(tick_field "$OUT" tick3 ext)" 5
assert_eq "LS2 never scales in however often it samples" "0 0 0 0 0" "$(scales "$OUT")"
case_ran LS2

# ── LS3 hysteresis: engage 100 x2, release <50 x3, hold in between ──────────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400 0 400 400 250 30 30 30 70 400 400 70 30 30
load_drv "$C" "$S" -- 'ls_ticks 15'
assert_eq "LS3 spike / engage / update / hold / release / hold / re-engage / hold" \
    "0 0 0 0 4 2 2 2 0 0 0 4 4 4 4" "$(scales "$OUT")"
case_ran LS3

# ── LS4 unmeasurable after an engaged sample: the hysteresis resets, no hold ─
# There is no hold: an unmeasurable sample resets scale_in/above/below to 0 and the pool comes
# back to base - 1 (the allocator stops growth on that sample instead).
# ls4_kind <label> <how> — snaps 1-3 engage at tick 3 (400 x2); snap.4 is broken by <how>.
ls4_kind() {
    C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
    gen_snaps "$S" own0 400 400 400 400 400
    local f="$S/snap.4"
    case "$2" in
        fail) printf 'FAIL\n' > "$f" ;;
        timeout) mv "$f" "$f.after"; printf 'SLEEP\n' > "$f" ;;
        nonnum) printf '7200 1 abc 4096 x\n' >> "$f" ;;
        noroot) sed -i "/^$ROOT_PID 1 /d" "$f" ;;
        shrink) sed -i 's/^host_busy_ms=.*/host_busy_ms=1/' "$f" ;;
        dwall) sed -i "s/^wall_ms=.*/wall_ms=$(sed -n 's/^wall_ms=//p' "$S/snap.3")/" "$f" ;;
        format1) sed -i '/^snapshot=2$/d' "$f" ;;
    esac
    load_drv "$C" "$S" -- 'ls_ticks 6'
    assert_eq "LS4 $1: engaged at tick 3 first (positive control)" "4" "$(tick_field "$OUT" tick3 scale)"
    assert_eq "LS4 $1: state=unmeasurable" "unmeasurable" "$(tick_field "$OUT" tick4 state)"
    assert_eq "LS4 $1: the hysteresis resets: scale_in / above / below 0" "0 0 0" \
        "$(tick_field "$OUT" tick4 scale) $(tick_field "$OUT" tick4 above) $(tick_field "$OUT" tick4 below)"
    assert_eq "LS4 $1: the sample carries no held_samples key" "" "$(tick_field "$OUT" tick4 held)"
    assert_eq "LS4 $1: the pool is base - 1 = 11 (no scale-in held)" "11" "$(tick_field "$OUT" tick4 pool)"
}
ls4_kind "probe failure" fail
assert_eq "LS4 probe failure: the next measured sample starts the engage count afresh (above 1, scale 0)" \
    "0 1" "$(tick_field "$OUT" tick5 scale) $(tick_field "$OUT" tick5 above)"
assert_eq "LS4 probe failure: the second measured sample above engages again" "4" "$(tick_field "$OUT" tick6 scale)"
ls4_kind "probe timeout" timeout
ls4_kind "malformed process line" nonnum
ls4_kind "no root in the snapshot" noroot
ls4_kind "host counter went backwards" shrink
ls4_kind "wall clock did not advance" dwall
ls4_kind "format-1 snapshot (no snapshot=2 line)" format1
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400
load_drv "$C" "$S" -- 'ls_ticks 1'
assert_eq "LS4 no previous snapshot: state=unmeasurable" "unmeasurable" "$(tick_field "$OUT" tick1 state)"
assert_eq "LS4 no previous sample: scale_in 0" "0" "$(tick_field "$OUT" tick1 scale)"
assert_eq "LS4 no previous sample: the sample carries no held_samples key" "" "$(tick_field "$OUT" tick1 held)"
if [ -s "$C/load/snapshot.2" ] && [ ! -e "$C/load/snapshot" ]; then
    pass "LS4 the first tick stores load/snapshot.2 (not the format-1 load/snapshot)"
else
    fail "LS4 load/snapshot.2 missing, or load/snapshot written" "rc=$RC err=$(printf '%q' "$ERR")"
fi
case_ran LS4

case_end

case_begin "load-reserved-cores" "bin/lib/test-host-load.sh"

# ── LS15 16 CPUs, base 12: 4 reserved cores; only the excess scales in ──────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400 400 400
load_drv "$C" "$S" "PATH=$CPU16:$PATH" -- 'ls_ticks 4'
assert_eq "LS15 reserved_cores = 16 - 12" "4" "$(tick_field "$OUT" tick4 res)"
assert_near "LS15 the external load is still reported in full" 400 "$(tick_field "$OUT" tick4 ext)"
assert_eq "LS15 4 external cores within 4 reserved: never scales in" "0 0 0 0" "$(scales "$OUT")"
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 500 500 600
load_drv "$C" "$S" "PATH=$CPU16:$PATH" -- 'ls_ticks 4'
assert_eq "LS15 5 cores engage at 1 over the reserve; 6 cores give 2" "0 0 1 2" "$(scales "$OUT")"
assert_eq "LS15 pool 11 - 2" "9" "$(tick_field "$OUT" tick4 pool)"
# Release: 6 cores engage 2 over the reserve; 4 cores (excess 0 < 50) release on the 3rd sample.
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 600 600 400 400 400
load_drv "$C" "$S" "PATH=$CPU16:$PATH" -- 'ls_ticks 6'
assert_eq "LS15 release: engage 2 at the 2nd sample, kept for 2 samples within the reserve, 0 at the 3rd" \
    "0 0 2 2 2 0" "$(scales "$OUT")"
assert_eq "LS15 release: pool 9 while kept" "9" "$(tick_field "$OUT" tick5 pool)"
assert_eq "LS15 release: the pool comes back to 11" "11" "$(tick_field "$OUT" tick6 pool)"
# 4.7 cores (excess ~70: between 50 and 100) restarts the release count.
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 600 600 400 400 470 400 400 400
load_drv "$C" "$S" "PATH=$CPU16:$PATH" -- 'ls_ticks 9'
assert_eq "LS15 release: an excess in the dead band resets the count; 3 fresh samples below release" \
    "0 0 2 2 2 2 2 2 0" "$(scales "$OUT")"
assert_eq "LS15 release after the reset: pool 11" "11" "$(tick_field "$OUT" tick9 pool)"
case_ran LS15

case_end

case_begin "load-reader" "bin/lib/test-host-load.sh"

# ── LS5 a stale sample (older than 3 heartbeats) reads as 0 ─────────────────
C="$(new_cache)"; S="$(new_snaps)"
mk_sample "$C" "$(($(now_epoch) - 10))" 4
load_drv "$C" "$S" -- 'thl_load_scale_in; echo "si=$THL_LOAD_SCALE_IN"'
assert_eq "LS5 sample 10s old, heartbeat 2s: reader returns 0" "0" "$(kv_of "$OUT" si)"
mk_sample "$C" "$(($(now_epoch) - 3))" 4
load_drv "$C" "$S" -- 'thl_load_scale_in; echo "si=$THL_LOAD_SCALE_IN"'
assert_eq "LS5 sample 3s old: reader returns its scale_in 4" "4" "$(kv_of "$OUT" si)"
case_ran LS5

# ── LS6 mode off: the tick writes state=off without the probe or a snapshot ──
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400 400
load_drv "$C" "$S" AUTO_CONFIG_TEST_MAX_JOBS=off TEST_MAX_JOBS_PER_HOST=12 -- \
    'thl_load_tick; thl_load_tick; echo "tick_rc=$?"; echo "st=$(ls_key state)"; echo "si=$(ls_key scale_in)"'
assert_eq "LS6 driver rc 0" "0" "$RC"
assert_eq "LS6 mode off: the probe never ran" "0" "$(probe_calls "$S")"
assert_eq "LS6 mode off: the sample says state=off" "off" "$(kv_of "$OUT" st)"
assert_eq "LS6 mode off: scale_in 0" "0" "$(kv_of "$OUT" si)"
if [ -e "$C/load/snapshot.2" ] || [ -e "$C/load/snapshot" ]; then
    fail "LS6 mode off wrote a snapshot"
else
    pass "LS6 mode off writes no snapshot"
fi
mk_sample "$C" "$(now_epoch)" 4
load_drv "$C" "$S" AUTO_CONFIG_TEST_MAX_JOBS=off -- 'thl_load_scale_in; echo "si=$THL_LOAD_SCALE_IN"'
assert_eq "LS6 mode off: a fresh scale_in=4 sample still reads 0" "0" "$(kv_of "$OUT" si)"
case_ran LS6

# ── LS17 mode on: one probe per heartbeat, however often thl_load_tick is called ─
# Heartbeat 60s keeps calls 2-4 inside the first period; the sample's generation is its
# measured_at (the whole file, rows included, must not change while it is fresh).
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400
load_drv "$C" "$S" TEST_LANES_HEARTBEAT=60 -- '
L="$THL_CACHE_ROOT/load"
thl_load_tick; cp "$L/sample" "$L/s1.keep"; echo "c1=$(cat "$LS_SNAP_DIR/count")"
thl_load_tick; thl_load_tick; thl_load_tick
echo "c4=$(cat "$LS_SNAP_DIR/count")"
cmp -s "$L/s1.keep" "$L/sample"; echo "same=$?"
echo "rows1=$(grep -c "^alloc\." "$L/s1.keep")"; echo "row1=$(sed -n "s/^alloc\.[0-9.]*\.77=//p" "$L/s1.keep")"
ls_age 61; echo "aged=$(ls_key measured_at)"
thl_load_tick
echo "c5=$(cat "$LS_SNAP_DIR/count")"; echo "m5=$(ls_key measured_at)"; echo "st5=$(ls_key state)"
echo "rows5=$(grep -c "^alloc\." "$L/sample")"
thl_load_tick; echo "c6=$(cat "$LS_SNAP_DIR/count")"'
assert_eq "LS17 driver rc 0" "0" "$RC"
assert_eq "LS17 the first tick probes once" "1" "$(kv_of "$OUT" c1)"
assert_eq "LS17 three more ticks within the period: still 1 probe call" "1" "$(kv_of "$OUT" c4)"
assert_eq "LS17 the sample (header and alloc rows) is byte-identical across the calls" "0" "$(kv_of "$OUT" same)"
assert_eq "LS17 the first sample carries the run's alloc row" "1" "$(kv_of "$OUT" rows1)"
assert_eq "LS17 the row: initial width 4, ssthresh = top 11, share 11, slow-start" "4 11 11 slow-start" "$(kv_of "$OUT" row1)"
assert_eq "LS17 the period elapsed (sample aged 61s): the next tick probes again" "2" "$(kv_of "$OUT" c5)"
LS17_AGED="$(kv_of "$OUT" aged)"; LS17_M5="$(kv_of "$OUT" m5)"
[[ $LS17_M5 =~ ^[0-9]+$ && $LS17_AGED =~ ^[0-9]+$ ]] && [ "$LS17_M5" -gt "$LS17_AGED" ] \
    && pass "LS17 a new sample generation (measured_at $LS17_AGED -> $LS17_M5)" \
    || fail "LS17 no new sample generation" "aged=$LS17_AGED m5=$LS17_M5 out=$(printf '%q' "$OUT")"
assert_eq "LS17 the new sample is measured against the kept snapshot" "ok" "$(kv_of "$OUT" st5)"
assert_eq "LS17 the new sample still carries the run's alloc row" "1" "$(kv_of "$OUT" rows5)"
assert_eq "LS17 a tick right after the new sample does not probe" "2" "$(kv_of "$OUT" c6)"
case_ran LS17

# ── LS7 the reader never evaluates the file; bad files read as unmeasurable ──
C="$(new_cache)"; S="$(new_snaps)"
LS7_MARK="$TMPDIR_BASE/ls7-pwned"
ls7_read() { load_drv "$C" "$S" -- 'thl_load_scale_in; echo "si=$THL_LOAD_SCALE_IN"'; kv_of "$OUT" si; }
mk_sample "$C" "$(now_epoch)" 4
assert_eq "LS7 positive control: a valid fresh sample reads 4" "4" "$(ls7_read)"
mk_sample "$C" "$(now_epoch)" 4
sed -i "s|^scale_in=.*|scale_in=\$(touch $LS7_MARK)|" "$C/load/sample"
assert_eq "LS7 command substitution in scale_in: reads 0" "0" "$(ls7_read)"
[ -e "$LS7_MARK" ] && fail "LS7 the reader executed the injected command" || pass "LS7 the injected command never ran"
mk_sample "$C" "$(now_epoch)" 4; printf 'bogus=1\n' >> "$C/load/sample"
assert_eq "LS7 unknown key: reads 0" "0" "$(ls7_read)"
mk_sample "$C" "$(now_epoch)" 4; printf 'scale_in=4\n' >> "$C/load/sample"
assert_eq "LS7 duplicate key: reads 0" "0" "$(ls7_read)"
mk_sample1 "$C" "$(now_epoch)" 4
assert_eq "LS7 a schema-1 sample: reads 0" "0" "$(ls7_read)"
case_ran LS7

# ── LS12 the claim: a held claim skips the measurement, a stale one is reclaimed ─
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
gen_snaps "$S" own0 400 400
LS12_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$LS12_OLD" 0 0
mkdir -p "$C/load/.claim"
load_drv "$C" "$S" -- 'thl_load_tick; echo "m=$(ls_key measured_at)"'
assert_eq "LS12 positive control: the sample was due (driver rc 0)" "0" "$RC"
assert_eq "LS12 held claim: the probe is not run" "0" "$(probe_calls "$S")"
assert_eq "LS12 held claim: the sample is left as it was" "$LS12_OLD" "$(kv_of "$OUT" m)"
touch -d "@$(($(now_epoch) - 60))" "$C/load/.claim"
load_drv "$C" "$S" -- 'thl_load_tick; echo "m=$(ls_key measured_at)"'
assert_eq "LS12 stale claim (older than 3 heartbeats): reclaimed and measured" "1" "$(probe_calls "$S")"
[ "$(kv_of "$OUT" m)" != "$LS12_OLD" ] && [ -n "$(kv_of "$OUT" m)" ] \
    && pass "LS12 stale claim: a new sample was written" || fail "LS12 stale claim: sample not rewritten" "out=$(printf '%q' "$OUT")"
[ -e "$C/load/.claim" ] && fail "LS12 the claim is still held after the tick" || pass "LS12 the claim is released after the tick"
# A claim reclaimed mid-probe (the slow run must not write the sample nor release the claim of
# the run that took over, #2692) is covered by CL1-CL3 in claim-cases.sh.
case_ran LS12

# ── LS14 the pool floor: scale_in >= pool still leaves 1 to the first run ───
C="$(new_cache)"; S="$(new_snaps)"
mk_record "$C" 12
mk_sample "$C" "$(now_epoch)" 20
mk_presence "$C" "$LIVE_SLEEP.$(($(now_epoch) + 100)).1401" "$LIVE_SLEEP" "$(($(now_epoch) + 100))" 12 1000
load_drv "$C" "$S" TEST_LANES_HEARTBEAT=60 -- 'thl_run_all_lease 11; echo "lease=$THL_GRANTED"; thl_rebalance 0; echo "granted=$THL_GRANTED"; thl_release_all'
assert_eq "LS14 scale_in 20 over pool 11: the earliest run-all still gets 1" "1" "$(kv_of "$OUT" granted)"
case_ran LS14

case_end

grp_done sampler-cases.sh
