#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/sampler-cases.sh — the sampler (thl_load_tick), the
# hysteresis, the reader (thl_load_scale_in) and the pool it shrinks: LS1-LS7, LS12, LS14.

case_begin "load-sampler-hysteresis" "bin/lib/test-host-load.sh"

# ── LS1 I/O-bound own tests + 4 cores of external load ─────────────────────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
gen_snaps "$S" own0 400 400
load_drv "$C" "$S" -- 'ls_ticks 3'
assert_eq "LS1 driver loads the load lib (rc 0)" "0" "$RC"
assert_near "LS1 external_centicores ~400 on the first measured tick" 400 "$(tick_field "$OUT" tick2 ext)"
assert_eq "LS1 scale_in 4 on the second consecutive sample above the engage threshold" "0 0 4" "$(scales "$OUT")"
mk_record "$C" 12
load_drv "$C" "$S" TEST_LANES_HEARTBEAT=60 -- 'thl_run_all_lease 20; thl_rebalance 0; echo "granted=$THL_GRANTED"; thl_release_all'
assert_eq "LS1 max jobs per host 12: pool 11 - load scale-in 4 = 7" "7" "$(kv_of "$OUT" granted)"
case_ran LS1

# ── LS2 CPU-heavy own tests only: their descendants explain all host busy time ─
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
gen_snaps "$S" ownheavy 0 0 0 0
load_drv "$C" "$S" -- 'ls_ticks 5'
assert_near "LS2 8 cores of own descendants are not external load" 0 "$(tick_field "$OUT" tick3 ext)" 5
assert_eq "LS2 never scales in however often it samples" "0 0 0 0 0" "$(scales "$OUT")"
case_ran LS2

# ── LS3 hysteresis: engage 100 x2, release <50 x3, hold in between ──────────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
gen_snaps "$S" own0 400 0 400 400 250 30 30 30 70 400 400 70 30 30
load_drv "$C" "$S" -- 'ls_ticks 15'
assert_eq "LS3 spike / engage / update / hold / release / hold / re-engage / hold" \
    "0 0 0 0 4 2 2 2 0 0 0 4 4 4 4" "$(scales "$OUT")"
case_ran LS3

# ── LS4 unmeasurable: never scales in, and an engaged scale-in is released ──
# ls4_kind <label> <how> — snaps 1-3 engage at tick 3 (400 x2); snap.4 is broken by <how>.
ls4_kind() {
    C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
    gen_snaps "$S" own0 400 400 400 400 400
    local f="$S/snap.4"
    case "$2" in
        fail) printf 'FAIL\n' > "$f" ;;
        timeout) mv "$f" "$f.after"; printf 'SLEEP\n' > "$f" ;;
        nonnum) printf '7200 1 abc\n' >> "$f" ;;
        noroot) sed -i "/^$ROOT_PID 1 /d" "$f" ;;
        shrink) sed -i 's/^host_busy_ms=.*/host_busy_ms=1/' "$f" ;;
        dwall) sed -i "s/^wall_ms=.*/wall_ms=$(sed -n 's/^wall_ms=//p' "$S/snap.3")/" "$f" ;;
    esac
    load_drv "$C" "$S" -- 'ls_ticks 6'
    assert_eq "LS4 $1: engaged at tick 3 first (positive control)" "4" "$(tick_field "$OUT" tick3 scale)"
    assert_eq "LS4 $1: state=unmeasurable" "unmeasurable" "$(tick_field "$OUT" tick4 state)"
    assert_eq "LS4 $1: scale_in drops to 0" "0" "$(tick_field "$OUT" tick4 scale)"
}
ls4_kind "probe failure" fail
assert_eq "LS4 probe failure: the counters reset, so one more sample does not re-engage" "0" "$(tick_field "$OUT" tick5 scale)"
assert_eq "LS4 probe failure: two more samples re-engage" "4" "$(tick_field "$OUT" tick6 scale)"
ls4_kind "probe timeout" timeout
ls4_kind "non-numeric process line" nonnum
ls4_kind "no root in the snapshot" noroot
ls4_kind "host counter went backwards" shrink
ls4_kind "wall clock did not advance" dwall
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
gen_snaps "$S" own0 400
load_drv "$C" "$S" -- 'ls_ticks 1'
assert_eq "LS4 no previous snapshot: state=unmeasurable" "unmeasurable" "$(tick_field "$OUT" tick1 state)"
assert_eq "LS4 no previous snapshot: scale_in 0" "0" "$(tick_field "$OUT" tick1 scale)"
[ -s "$C/load/snapshot" ] && pass "LS4 the first tick stores load/snapshot for the next one" \
    || fail "LS4 load/snapshot missing after the first tick" "rc=$RC err=$(printf '%q' "$ERR")"
case_ran LS4

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

# ── LS6 mode off: the sampler never runs, the reader returns 0 ──────────────
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
gen_snaps "$S" own0 400 400
load_drv "$C" "$S" AUTO_CONFIG_TEST_MAX_JOBS=off -- 'thl_load_tick; thl_load_tick; echo "tick_rc=$?"'
assert_eq "LS6 driver rc 0" "0" "$RC"
assert_eq "LS6 mode off: the probe never ran" "0" "$(probe_calls "$S")"
[ -e "$C/load/snapshot" ] && fail "LS6 mode off wrote load/snapshot" || pass "LS6 mode off writes no snapshot"
mk_sample "$C" "$(now_epoch)" 4
load_drv "$C" "$S" AUTO_CONFIG_TEST_MAX_JOBS=off -- 'thl_load_scale_in; echo "si=$THL_LOAD_SCALE_IN"'
assert_eq "LS6 mode off: a fresh scale_in=4 sample still reads 0" "0" "$(kv_of "$OUT" si)"
case_ran LS6

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
case_ran LS7

# ── LS12 the claim: a held claim skips the measurement, a stale one is reclaimed ─
C="$(new_cache)"; S="$(new_snaps)"; mk_slot "$C" 1 "$LIVE_SLEEP"
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
