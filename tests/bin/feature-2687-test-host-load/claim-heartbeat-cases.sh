#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/claim-heartbeat-cases.sh — CL10-CL14 (#2692): the run that
# takes load/.claim records its own heartbeat in the claim; a reclaimer judges staleness by three
# times that recorded heartbeat, falling back to its own heartbeat when none is recorded or it is
# invalid. Each try re-creates the holder's claim, ages it with the claim dir's mtime (touch -d) plus
# a frozen _thl_now, and lets a reclaimer with heartbeat 1 call _thl_load_claim. The holder's claim is
# taken by the real _thl_load_claim / thl_load_tick, so the tests do not assume the record's format;
# only CL12 c2 (corrupt) assumes the heartbeat lives in a file inside .claim other than owner, or on
# owner's lines after the first (the token) — it overwrites exactly those.
# CL15: a tick whose owner token write fails writes no sample; a later tick reclaims and recovers.
# CL16: a holder whose heartbeat write fails is judged by the reclaimer's own heartbeat.

case_begin "load-claim-recorded-heartbeat" "bin/lib/test-host-load.sh"

CLH_LIB='
L="$THL_CACHE_ROOT/load"; mkdir -p "$L"
printf -v B "%(%s)T" -1
clh_corrupt() {
    local f n c=0
    for f in "$L/.claim"/* "$L/.claim"/.[!.]*; do
        [ -f "$f" ] || continue
        if [ "${f##*/}" = owner ]; then
            n="$(wc -l < "$f")"
            [ "$n" -gt 1 ] || continue
            { head -n 1 "$f"; printf "%b" "$1"; } > "$f.tmp"; mv -f "$f.tmp" "$f"
        else
            printf "%b" "$1" > "$f"
        fi
        c=$((c + 1))
    done
    echo "$2_corrupted=$c"
}
clh_hold() {
    rm -rf "$L/.claim" "$L"/.grave.* 2>/dev/null; rm -f "$THL_CACHE_ROOT/h.tok"
    case "$1" in
        bare) mkdir "$L/.claim"; printf "bare.0.0\n" > "$L/.claim/owner"; printf "bare.0.0\n" > "$THL_CACHE_ROOT/h.tok" ;;
        tick) ( TEST_LANES_HEARTBEAT=7; _thl_load_holds() { return 1; }; thl_load_tick
                printf "%s\n" "${_THL_CLAIM_TOKEN:-}" > "$THL_CACHE_ROOT/h.tok" ) ;;
        hbfail) ( printf() { if [ "$#" = 2 ] && [ "$1" = "%s\n" ] && [ "$2" = 60 ]; then
                      : > "$THL_CACHE_ROOT/hb.failed"; return 1; fi; builtin printf "$@"; }
                  _thl_load_claim "$L" 60 && printf "%s\n" "${_THL_CLAIM_TOKEN:-}" > "$THL_CACHE_ROOT/h.tok" ) ;;
        *) ( _thl_load_claim "$L" "$1" && printf "%s\n" "${_THL_CLAIM_TOKEN:-}" > "$THL_CACHE_ROOT/h.tok" ) ;;
    esac
}
clh_case() {
    local o="" r="" h=""
    clh_hold "$1"
    { IFS= read -r h < "$THL_CACHE_ROOT/h.tok"; } 2>/dev/null
    { IFS= read -r o < "$L/.claim/owner"; } 2>/dev/null
    [ -n "$h" ] && [ "$o" = "$h" ] && echo "$2_held=1" || echo "$2_held=0"
    [ "$#" -ge 4 ] && clh_corrupt "$4" "$2"
    touch -d "@$B" "$L/.claim"
    CLH_AGE="$3"
    ( _thl_now() { THL_NOW=$((B + CLH_AGE)); }
      _thl_load_claim "$L" "${CLH_RP:-1}"; echo "$2_rc=$?"
      printf "%s\n" "${_THL_CLAIM_TOKEN:-}" > "$THL_CACHE_ROOT/r.tok" )
    o=""; { IFS= read -r o < "$L/.claim/owner"; } 2>/dev/null
    { IFS= read -r r < "$THL_CACHE_ROOT/r.tok"; } 2>/dev/null
    [ -n "$o" ] && [ "$o" = "$h" ] && echo "$2_kept=1" || echo "$2_kept=0"
    [ -n "$o" ] && [ "$o" = "$r" ] && echo "$2_mine=1" || echo "$2_mine=0"
    echo "$2_graves=$(ls -A "$L" | grep -c "^\.grave")"
}
'

# clh_drv <snippet> — one driver run with a lane and a live run, CLH_LIB loaded first.
clh_drv() {
    C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
    load_drv "$C" "$(new_snaps)" -- "$CLH_LIB$1"
}
# clh_held <id> <tag> <what> — the positive control: the holder's claim was taken.
clh_held() {
    assert_eq "$1 positive control: $3 holds load/.claim before the reclaimer runs ($2)" "1" "$(kv_of "$OUT" "$2_held")"
}
# clh_keeps <id> <tag> <what> — the reclaimer leaves the holder's claim alone.
clh_keeps() {
    assert_eq "$1 $3: _thl_load_claim returns 1" "1" "$(kv_of "$OUT" "$2_rc")"
    assert_eq "$1 $3: load/.claim/owner is still the holder's token" "1" "$(kv_of "$OUT" "$2_kept")"
}
# clh_takes <id> <tag> <what> — the reclaimer takes the claim through the grave.
clh_takes() {
    assert_eq "$1 $3: _thl_load_claim returns 0" "0" "$(kv_of "$OUT" "$2_rc")"
    assert_eq "$1 $3: load/.claim/owner is now the reclaimer's token" "1" "$(kv_of "$OUT" "$2_mine")"
    assert_eq "$1 $3: no grave is left" "0" "$(kv_of "$OUT" "$2_graves")"
}

# ── CL10 holder heartbeat 60, reclaimer heartbeat 1, claim 10 s old ──────────
# 10 s >= 3 x 1 (the reclaimer's own) but < 3 x 60 (the recorded one): the claim is not stale.
clh_drv 'clh_case 60 a10 10'
clh_held CL10 a10 "the holder with heartbeat 60"
clh_keeps CL10 a10 "a 10 s old claim recorded with heartbeat 60 is not reclaimed by heartbeat 1"
case_ran CL10

# ── CL11 holder heartbeat 60: reclaimed at 3 x 60, not one second before ─────
clh_drv 'clh_case 60 a300 300; clh_case 60 a180 180; clh_case 60 a179 179'
clh_held CL11 a300 "the holder with heartbeat 60"
clh_takes CL11 a300 "positive control: a 300 s old claim recorded with heartbeat 60 is reclaimed"
clh_held CL11 a180 "the holder with heartbeat 60"
clh_takes CL11 a180 "at exactly 3 x 60 = 180 s the claim is reclaimed"
clh_held CL11 a179 "the holder with heartbeat 60"
clh_keeps CL11 a179 "at 179 s (one second below 3 x 60) the claim is not reclaimed"
case_ran CL11

# ── CL12 no recorded heartbeat (c1) or an invalid one (c2): own heartbeat ────
clh_drv 'clh_case bare b3 3; clh_case bare b2 2'
clh_held CL12 b3 "a bare claim (mkdir + owner, no heartbeat)"
clh_takes CL12 b3 "c1 a bare claim 3 s old (3 x the reclaimer's 1) is reclaimed"
clh_held CL12 b2 "a bare claim (mkdir + owner, no heartbeat)"
clh_keeps CL12 b2 "c1 a bare claim 2 s old (below 3 x 1) is not reclaimed"
case_ran CL12

# name|tag|the value written over the recorded heartbeat (printf %b) — every row falls back to 1.
CLH_BAD='non-integer|g|garbage\n
zero|z|0\n
empty|e|
negative|n|-5\n
overlong|h|99999999999999999999\n'
_clh_snip=""
while IFS='|' read -r _w _t _v; do
    [ -n "$_w" ] || continue
    _clh_snip="$_clh_snip clh_case 60 ${_t}3 3 \"$_v\"; clh_case 60 ${_t}2 2 \"$_v\";"
done <<< "$CLH_BAD"
clh_drv "$_clh_snip"
while IFS='|' read -r _w _t _v; do
    [ -n "$_w" ] || continue
    clh_held CL12 "${_t}3" "the holder with heartbeat 60"
    _n="$(kv_of "$OUT" "${_t}3_corrupted")"
    [[ $_n =~ ^[0-9]+$ ]] && [ "$_n" -ge 1 ] \
        && pass "CL12 c2 positive control: the holder's claim carries a recorded heartbeat to corrupt ($_w, $_n file(s))" \
        || fail "CL12 c2 the holder's claim records no heartbeat besides the owner token ($_w)" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    clh_takes CL12 "${_t}3" "c2 a claim whose recorded heartbeat is $_w, 3 s old, is reclaimed (fallback to 1)"
    clh_held CL12 "${_t}2" "the holder with heartbeat 60"
    clh_keeps CL12 "${_t}2" "c2 a claim whose recorded heartbeat is $_w, 2 s old, is not reclaimed (fallback to 1)"
done <<< "$CLH_BAD"
case_ran CL12

# ── CL13 a tick with heartbeat 7 records it in the claim it takes ────────────
# The tick's _thl_load_holds is stubbed false, so it neither writes the sample nor releases the claim.
clh_drv 'clh_case tick t10 10; clh_case tick t20 20; clh_case tick t21 21'
clh_held CL13 t10 "the tick with heartbeat 7"
clh_keeps CL13 t10 "a 10 s old claim taken by a heartbeat-7 tick is not reclaimed by heartbeat 1"
clh_held CL13 t20 "the tick with heartbeat 7"
clh_keeps CL13 t20 "at 20 s (one second below 3 x 7) the claim is not reclaimed"
clh_held CL13 t21 "the tick with heartbeat 7"
clh_takes CL13 t21 "at exactly 3 x 7 = 21 s the claim is reclaimed"
case_ran CL13

# ── CL14 the reverse: holder heartbeat 1, reclaimer heartbeat 60 ─────────────
# The recorded 1 decides (3 s), not the larger of the two; catches a max(recorded, own) implementation.
clh_drv 'CLH_RP=60; clh_case 1 r2 2; clh_case 1 r3 3'
clh_held CL14 r2 "the holder with heartbeat 1"
clh_keeps CL14 r2 "a 2 s old claim recorded with heartbeat 1 is not reclaimed by heartbeat 60"
clh_held CL14 r3 "the holder with heartbeat 1"
clh_takes CL14 r3 "a 3 s old claim recorded with heartbeat 1 is reclaimed by heartbeat 60"
case_ran CL14

# ── CL15 the owner token cannot be written: no sample, a later tick recovers ─
# mkdir is overridden to also create load/.claim/owner as a directory, so the owner write fails.
# That tick does not hold the claim: it leaves the sample alone and the claim in place. Once the
# claim is past three heartbeats old, the next tick reclaims it, rewrites the sample and releases.
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_S="$(new_snaps)"
snap2 "$CL_S/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_S/snap.2" 113111 1002000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$CL_S" -- '
L="$THL_CACHE_ROOT/load"
cp "$L/sample" "$THL_CACHE_ROOT/sample.before"
mkdir() { command mkdir "$@" || return; case "${!#}" in */load/.claim) command mkdir "${!#}/owner" ;; esac; }
thl_load_tick; echo "rc1=$?"
[ -d "$L/.claim/owner" ] && echo "hit=1" || echo "hit=0"
cmp -s "$THL_CACHE_ROOT/sample.before" "$L/sample" && echo "same=1" || echo "same=0"
[ -d "$L/.claim" ] && echo "claim=1" || echo "claim=0"
unset -f mkdir
touch -d "@$(($(date +%s) - 60))" "$L/.claim"
thl_load_tick; echo "rc2=$?"
echo "m2=$(ls_key measured_at)"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -e "$L/.claim" ] && echo "claim2=1" || echo "claim2=0"
echo "graves=$(ls -A "$L" | grep -c "^\.grave")"'
assert_eq "CL15 positive control: the owner write was made to fail (load/.claim/owner is a directory)" "1" "$(kv_of "$OUT" hit)"
assert_eq "CL15 the tick that could not write its owner token completes (rc 0)" "0" "$(kv_of "$OUT" rc1)"
assert_eq "CL15 that tick does not write load/sample (byte-identical)" "1" "$(kv_of "$OUT" same)"
assert_eq "CL15 that tick leaves load/.claim in place" "1" "$(kv_of "$OUT" claim)"
assert_eq "CL15 the next tick, past three heartbeats, completes (rc 0)" "0" "$(kv_of "$OUT" rc2)"
_cl15_m="$(kv_of "$OUT" m2)"
[[ $_cl15_m =~ ^[0-9]+$ ]] && [ "$_cl15_m" -gt "$CL_OLD" ] \
    && pass "CL15 the next tick reclaims the claim and rewrites load/sample (measured_at advanced)" \
    || fail "CL15 the next tick did not rewrite load/sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL15 the rewritten sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL15 the next tick releases its claim" "0" "$(kv_of "$OUT" claim2)"
assert_eq "CL15 no grave is left" "0" "$(kv_of "$OUT" graves)"
case_ran CL15

# ── CL16 the holder's heartbeat write fails: the reclaimer falls back to its own ─
# printf is overridden to fail only on the holder's heartbeat value (60), so the claim is taken
# with its owner token but no recorded heartbeat; the reclaimer with heartbeat 1 judges by 3 x 1.
clh_drv 'clh_case hbfail f3 3; [ -e "$THL_CACHE_ROOT/hb.failed" ] && echo "f3_hit=1" || echo "f3_hit=0"
rm -f "$THL_CACHE_ROOT/hb.failed"; clh_case hbfail f2 2
[ -e "$THL_CACHE_ROOT/hb.failed" ] && echo "f2_hit=1" || echo "f2_hit=0"'
assert_eq "CL16 positive control: the holder's heartbeat write was made to fail (3 s try)" "1" "$(kv_of "$OUT" f3_hit)"
clh_held CL16 f3 "the holder with heartbeat 60 whose heartbeat write failed"
clh_takes CL16 f3 "a 3 s old claim whose heartbeat write failed is reclaimed by heartbeat 1"
assert_eq "CL16 positive control: the holder's heartbeat write was made to fail (2 s try)" "1" "$(kv_of "$OUT" f2_hit)"
clh_held CL16 f2 "the holder with heartbeat 60 whose heartbeat write failed"
clh_keeps CL16 f2 "a 2 s old claim whose heartbeat write failed is not reclaimed by heartbeat 1"
case_ran CL16

case_end

grp_done claim-heartbeat-cases.sh
