#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/claim-cases.sh — CL1-CL3: the load claim is reclaimed
# through the grave while its holder is still measuring (#2692). The run-all lane allocation
# sample is written and the claim released only while the run still holds the claim, so a slow
# run reclaimed mid-probe breaks neither the claim nor the sample of the run that took over.
# CL4: a failed mv of the sample keeps the old sample and still releases the claim.
# CL17: a failed temp file write of the sample does the same.
# CL5-CL7 (heartbeat 2 s): a tick past two heartbeats since taking the claim is invalidated and
# leaves the sample and the claim alone (CL5); one within two heartbeats writes and releases
# (CL6); once the left claim is three heartbeats old a later tick reclaims it (CL7).
# CL8-CL9: past two heartbeats only after the sample write keeps the claim (CL8); exactly two releases (CL9).

case_begin "load-claim-ownership" "bin/lib/test-host-load.sh"

# A slow probe: records the call, marks started, waits for go (at most 15 s), then answers.
CL_SLOW="$TMPDIR_BASE/probe-slow-claim.sh"
printf '%s\n' '#!/usr/bin/env bash' 'd="${LS_SNAP_DIR:?}"' 'printf "1\n" > "$d/count"; : > "$d/started"' \
    'for i in $(seq 1 150); do [ -e "$d/go" ] && break; sleep 0.1; done' 'cat "$d/snap.1"' > "$CL_SLOW"
chmod +x "$CL_SLOW"

# ── CL1 / CL3 A is reclaimed and finishes while B still holds the claim ────
# A takes the claim and blocks in its probe; the claim is aged past three heartbeats; B reclaims
# it and blocks in its own probe. A finishes first: it must leave B's claim and the sample alone
# (CL1). Then B finishes: it writes the sample and releases its claim (CL3).
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_SA="$(new_snaps)"; CL_SB="$(new_snaps)"
snap2 "$CL_SA/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_SB/snap.1" 222222 1000000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$(new_snaps)" "ALD=$LOAD_DRV" "SA=$CL_SA" "SB=$CL_SB" "SLOW=$CL_SLOW" -- '
TEST_LANES_LOAD_PROBE_CMD="$SLOW" LS_SNAP_DIR="$SA" bash "$ALD" thl_load_tick & a=$!
for i in $(seq 1 100); do [ -e "$SA/started" ] && break; sleep 0.1; done
touch -d "@$(($(date +%s) - 60))" "$THL_CACHE_ROOT/load/.claim"
TEST_LANES_LOAD_PROBE_CMD="$SLOW" LS_SNAP_DIR="$SB" bash "$ALD" thl_load_tick & b=$!
for i in $(seq 1 100); do [ -e "$SB/started" ] && break; sleep 0.1; done
[ -e "$SB/started" ] && echo "b_started=1" || echo "b_started=0"
: > "$SA/go"; wait "$a"; echo "a_rc=$?"
[ -d "$THL_CACHE_ROOT/load/.claim" ] && echo "claim_after_a=1" || echo "claim_after_a=0"
echo "m_after_a=$(ls_key measured_at)"
: > "$SB/go"; wait "$b"; echo "b_rc=$?"
echo "m_after_b=$(ls_key measured_at)"
_thl_sample_read "$THL_CACHE_ROOT/load/sample"; echo "f_ok=$?"
[ -d "$THL_CACHE_ROOT/load/.claim" ] && echo "claim_after_b=1" || echo "claim_after_b=0"
echo "graves=$(ls -A "$THL_CACHE_ROOT/load" | grep -c "^\.grave")"'
assert_eq "CL1 positive control: A ran its probe" "1" "$(probe_calls "$CL_SA")"
assert_eq "CL1 positive control: B reclaimed the stale claim and is in its probe" "1" "$(kv_of "$OUT" b_started)"
assert_eq "CL1 A's tick completes (rc 0)" "0" "$(kv_of "$OUT" a_rc)"
assert_eq "CL1 A, reclaimed, does not release B's claim (load/.claim still held)" "1" "$(kv_of "$OUT" claim_after_a)"
assert_eq "CL1 A, reclaimed, does not write the sample (measured_at unchanged)" "$CL_OLD" "$(kv_of "$OUT" m_after_a)"
case_ran CL1
assert_eq "CL3 B's tick completes (rc 0)" "0" "$(kv_of "$OUT" b_rc)"
_cl3_m="$(kv_of "$OUT" m_after_b)"
[[ $_cl3_m =~ ^[0-9]+$ ]] && [ "$_cl3_m" -gt "$CL_OLD" ] \
    && pass "CL3 B, still holding the claim, writes the sample" \
    || fail "CL3 B did not write the sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL3 B's sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL3 B releases its claim" "0" "$(kv_of "$OUT" claim_after_b)"
assert_eq "CL3 no grave is left" "0" "$(kv_of "$OUT" graves)"
case_ran CL3

# ── CL2 A is reclaimed and finishes after B already wrote and released ─────
# A's late finish must not overwrite B's sample (byte-identical to B's) nor leave anything.
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_SA="$(new_snaps)"; CL_SB="$(new_snaps)"
snap2 "$CL_SA/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_SB/snap.1" 222222 1000000 "$ROOT_PID 1 500 10240 bash"
load_drv "$C" "$CL_SB" "ALD=$LOAD_DRV" "SA=$CL_SA" "SLOW=$CL_SLOW" -- '
TEST_LANES_LOAD_PROBE_CMD="$SLOW" LS_SNAP_DIR="$SA" bash "$ALD" thl_load_tick & a=$!
for i in $(seq 1 100); do [ -e "$SA/started" ] && break; sleep 0.1; done
touch -d "@$(($(date +%s) - 60))" "$THL_CACHE_ROOT/load/.claim"
thl_load_tick
echo "b_m=$(ls_key measured_at)"; cp "$THL_CACHE_ROOT/load/sample" "$THL_CACHE_ROOT/sample.b"
sleep 1.2
: > "$SA/go"; wait "$a"; echo "a_rc=$?"
_thl_sample_read "$THL_CACHE_ROOT/sample.b"; echo "b_ok=$?"
_thl_sample_read "$THL_CACHE_ROOT/load/sample"; echo "f_ok=$?"
cmp -s "$THL_CACHE_ROOT/sample.b" "$THL_CACHE_ROOT/load/sample" && echo "same=1" || echo "same=0"
echo "left=$(ls -A "$THL_CACHE_ROOT/load" | tr "\n" " ")"'
assert_eq "CL2 positive control: the slow run A ran its probe once" "1" "$(probe_calls "$CL_SA")"
assert_eq "CL2 positive control: B reclaimed the claim and measured" "1" "$(probe_calls "$CL_SB")"
assert_eq "CL2 A's tick completes (rc 0)" "0" "$(kv_of "$OUT" a_rc)"
assert_eq "CL2 B's sample is well-formed" "0" "$(kv_of "$OUT" b_ok)"
assert_eq "CL2 the final sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL2 A, reclaimed, does not overwrite B's sample (byte-identical)" "1" "$(kv_of "$OUT" same)"
assert_eq "CL2 no temp file, grave or claim is left" "sample snapshot.2 " "$(kv_of "$OUT" left)"
case_ran CL2

# ── CL4 the sample's mv fails: the old sample stays, the claim is released ──
# mv is overridden to fail only onto load/sample; the tick must still return 0, keep the old
# sample byte-identical, remove its temp file and release the claim, so the next tick rewrites it.
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_S="$(new_snaps)"
snap2 "$CL_S/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_S/snap.2" 113111 1002000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$CL_S" -- '
L="$THL_CACHE_ROOT/load"
cp "$L/sample" "$THL_CACHE_ROOT/sample.before"
mv() { local a; for a; do :; done; case "$a" in */load/sample) : > "$THL_CACHE_ROOT/mv.failed"; return 1 ;; esac; command mv "$@"; }
thl_load_tick; echo "rc1=$?"
[ -e "$THL_CACHE_ROOT/mv.failed" ] && echo "mv_hit=1" || echo "mv_hit=0"
cmp -s "$THL_CACHE_ROOT/sample.before" "$L/sample" && echo "same=1" || echo "same=0"
[ -e "$L/.claim/owner" ] && echo "owner=1" || echo "owner=0"
[ -e "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "tmp=$(ls -A "$L" | grep -c "^sample\.new\.")"
unset -f mv
thl_load_tick; echo "rc2=$?"
echo "m2=$(ls_key measured_at)"; echo "schema2=$(ls_key schema)"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -e "$L/.claim" ] && echo "claim2=1" || echo "claim2=0"'
assert_eq "CL4 positive control: the tick reached the sample write and mv failed onto load/sample" "1" "$(kv_of "$OUT" mv_hit)"
assert_eq "CL4 the tick whose mv failed still completes (rc 0)" "0" "$(kv_of "$OUT" rc1)"
assert_eq "CL4 (a) load/sample is byte-identical to the sample before the tick" "1" "$(kv_of "$OUT" same)"
assert_eq "CL4 (b) load/.claim/owner is released" "0" "$(kv_of "$OUT" owner)"
assert_eq "CL4 (b) load/.claim is released" "0" "$(kv_of "$OUT" claim)"
assert_eq "CL4 (c) no load/sample.new.* temp file is left" "0" "$(kv_of "$OUT" tmp)"
assert_eq "CL4 (d) the next tick completes (rc 0)" "0" "$(kv_of "$OUT" rc2)"
_cl4_m="$(kv_of "$OUT" m2)"
[[ $_cl4_m =~ ^[0-9]+$ ]] && [ "$_cl4_m" -gt "$CL_OLD" ] \
    && pass "CL4 (d) the next tick rewrites load/sample (measured_at advanced)" \
    || fail "CL4 (d) the next tick did not rewrite load/sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL4 (d) the rewritten sample is schema 2" "2" "$(kv_of "$OUT" schema2)"
assert_eq "CL4 (d) the rewritten sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL4 (d) the next tick releases its claim" "0" "$(kv_of "$OUT" claim2)"
case_ran CL4

# ── CL17 the sample's temp file write fails: the same recovery as CL4 ───────
# RANDOM is seeded and every temp file name the seed can give is taken by a directory first, so the
# temp file cannot be opened; rm records being asked to remove such a directory (the failure branch).
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_S="$(new_snaps)"
snap2 "$CL_S/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_S/snap.2" 113111 1002000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$CL_S" -- '
L="$THL_CACHE_ROOT/load"
cp "$L/sample" "$THL_CACHE_ROOT/sample.before"
RANDOM=7; for i in $(seq 1 64); do command mkdir -p "$L/sample.new.$$.$RANDOM"; done; RANDOM=7
rm() { local a; for a; do case "$a" in */sample.new.*) [ -d "$a" ] && : > "$THL_CACHE_ROOT/w.failed" ;; esac; done; command rm "$@"; }
thl_load_tick; echo "rc1=$?"
unset -f rm
[ -e "$THL_CACHE_ROOT/w.failed" ] && echo "w_hit=1" || echo "w_hit=0"
cmp -s "$THL_CACHE_ROOT/sample.before" "$L/sample" && echo "same=1" || echo "same=0"
[ -e "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "tmp=$(find "$L" -maxdepth 1 -type f -name "sample.new.*" | grep -c .)"
command rm -rf "$L"/sample.new.*
thl_load_tick; echo "rc2=$?"
echo "m2=$(ls_key measured_at)"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -e "$L/.claim" ] && echo "claim2=1" || echo "claim2=0"'
assert_eq "CL17 positive control: the tick reached the sample write and could not open its temp file" "1" "$(kv_of "$OUT" w_hit)"
assert_eq "CL17 the tick whose temp file write failed still completes (rc 0)" "0" "$(kv_of "$OUT" rc1)"
assert_eq "CL17 load/sample is byte-identical to the sample before the tick" "1" "$(kv_of "$OUT" same)"
assert_eq "CL17 load/.claim is released" "0" "$(kv_of "$OUT" claim)"
assert_eq "CL17 no load/sample.new.* temp file is left" "0" "$(kv_of "$OUT" tmp)"
assert_eq "CL17 the next tick completes (rc 0)" "0" "$(kv_of "$OUT" rc2)"
_cl17_m="$(kv_of "$OUT" m2)"
[[ $_cl17_m =~ ^[0-9]+$ ]] && [ "$_cl17_m" -gt "$CL_OLD" ] \
    && pass "CL17 the next tick rewrites load/sample (measured_at advanced)" \
    || fail "CL17 the next tick did not rewrite load/sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL17 the rewritten sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL17 the next tick releases its claim" "0" "$(kv_of "$OUT" claim2)"
case_ran CL17

# ── CL5 / CL7 a tick past two heartbeats is invalidated; a later tick recovers ──
# Clock seam: the fast probe stub writes skew=5 when called (after the claim is taken), and the
# CL5 tick's _thl_now adds it, so only the checks after the probe see past two heartbeats (4 s),
# below the three (6 s) of a reclaim. Then the left claim and the sample are aged and a normal tick
# reclaims the claim; CL7 compares against measured_at just before that tick, not CL5's outcome.
CL_SKEW="$TMPDIR_BASE/probe-skew-claim.sh"
printf '%s\n' '#!/usr/bin/env bash' 'd="${LS_SNAP_DIR:?}"' 'printf "1\n" > "$d/count"; printf "5\n" > "$d/skew"' \
    'cat "$d/snap.1"' > "$CL_SKEW"
chmod +x "$CL_SKEW"
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_SA="$(new_snaps)"; CL_S="$(new_snaps)"
snap2 "$CL_SA/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
snap2 "$CL_S/snap.1" 222222 1000000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$CL_S" "SA=$CL_SA" "SKEW=$CL_SKEW" -- '
L="$THL_CACHE_ROOT/load"
cp "$L/sample" "$THL_CACHE_ROOT/sample.before"
(
    TEST_LANES_LOAD_PROBE_CMD="$SKEW"; LS_SNAP_DIR="$SA"
    _thl_now() {
        local s=0
        [ -f "$SA/skew" ] && { read -r s < "$SA/skew"; printf "x\n" >> "$SA/skewed"; }
        printf -v THL_NOW "%(%s)T" -1; THL_NOW=$((THL_NOW + s))
    }
    thl_load_tick; echo "a_rc=$?"
    printf "a_token=%s\n" "${_THL_CLAIM_TOKEN:-}"
)
echo "skewed=$(grep -c x "$SA/skewed" 2>/dev/null)"
o=""; { IFS= read -r o < "$L/.claim/owner"; } 2>/dev/null; echo "owner_token=$o"
cmp -s "$THL_CACHE_ROOT/sample.before" "$L/sample" && echo "same=1" || echo "same=0"
echo "m5=$(ls_key measured_at)"
[ -e "$L/.claim/owner" ] && echo "owner=1" || echo "owner=0"
[ -d "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "tmp=$(ls -A "$L" | grep -c "^sample\.new\.")"
[ -d "$L/.claim" ] && touch -d "@$(($(date +%s) - 60))" "$L/.claim"
ls_age 3; echo "m7_pre=$(ls_key measured_at)"
thl_load_tick; echo "rc7=$?"
echo "m7=$(ls_key measured_at)"
_thl_sample_read "$L/sample"; echo "f_ok7=$?"
[ -d "$L/.claim" ] && echo "claim7=1" || echo "claim7=0"
echo "graves7=$(ls -A "$L" | grep -c "^\.grave")"'
_cl5_tok="$(kv_of "$OUT" a_token)"
[[ -n $_cl5_tok && $_cl5_tok == "$(kv_of "$OUT" owner_token)" ]] \
    && pass "CL5 positive control: the tick took the claim (load/.claim/owner is its own token)" \
    || fail "CL5 the tick did not take the claim" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL5 positive control: the tick ran its probe once" "1" "$(probe_calls "$CL_SA")"
_cl5_sk="$(kv_of "$OUT" skewed)"
[[ $_cl5_sk =~ ^[0-9]+$ ]] && [ "$_cl5_sk" -ge 1 ] \
    && pass "CL5 positive control: the clock after the probe read the skew ($_cl5_sk calls)" \
    || fail "CL5 the clock seam was never read after the probe" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL5 the tick past two heartbeats completes (rc 0)" "0" "$(kv_of "$OUT" a_rc)"
assert_eq "CL5 the tick past two heartbeats does not write load/sample (byte-identical)" "1" "$(kv_of "$OUT" same)"
assert_eq "CL5 the tick past two heartbeats leaves measured_at unchanged" "$CL_OLD" "$(kv_of "$OUT" m5)"
assert_eq "CL5 the tick past two heartbeats does not remove load/.claim/owner" "1" "$(kv_of "$OUT" owner)"
assert_eq "CL5 the tick past two heartbeats does not remove load/.claim" "1" "$(kv_of "$OUT" claim)"
assert_eq "CL5 no load/sample.new.* temp file is left" "0" "$(kv_of "$OUT" tmp)"
case_ran CL5
assert_eq "CL7 positive control: the later tick ran its probe" "1" "$(probe_calls "$CL_S")"
assert_eq "CL7 the later tick completes (rc 0)" "0" "$(kv_of "$OUT" rc7)"
_cl7_m="$(kv_of "$OUT" m7)"; _cl7_p="$(kv_of "$OUT" m7_pre)"
[[ $_cl7_m =~ ^[0-9]+$ && $_cl7_p =~ ^[0-9]+$ ]] && [ "$_cl7_m" -gt "$_cl7_p" ] \
    && pass "CL7 the later tick reclaims the left claim and writes the sample" \
    || fail "CL7 the later tick did not write the sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL7 the later tick's sample is well-formed" "0" "$(kv_of "$OUT" f_ok7)"
assert_eq "CL7 the later tick releases its claim" "0" "$(kv_of "$OUT" claim7)"
assert_eq "CL7 no grave is left" "0" "$(kv_of "$OUT" graves7)"
case_ran CL7

# ── CL6 a slow tick still within two heartbeats writes and releases ─────────
C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
CL_SA="$(new_snaps)"
snap2 "$CL_SA/snap.1" 111111 1000000 "$ROOT_PID 1 500 10240 bash"
CL_OLD="$(($(now_epoch) - 10))"
mk_sample "$C" "$CL_OLD" 0 0
load_drv "$C" "$(new_snaps)" "ALD=$LOAD_DRV" "SA=$CL_SA" "SLOW=$CL_SLOW" -- '
L="$THL_CACHE_ROOT/load"
TEST_LANES_LOAD_PROBE_CMD="$SLOW" LS_SNAP_DIR="$SA" bash "$ALD" thl_load_tick & a=$!
for i in $(seq 1 100); do [ -e "$SA/started" ] && break; sleep 0.1; done
[ -e "$SA/started" ] && echo "a_started=1" || echo "a_started=0"
sleep 1; : > "$SA/go"; wait "$a"; echo "a_rc=$?"
echo "m6=$(ls_key measured_at)"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -d "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "tmp=$(ls -A "$L" | grep -c "^sample\.new\.")"'
assert_eq "CL6 positive control: the slow tick took the claim and is in its probe" "1" "$(kv_of "$OUT" a_started)"
assert_eq "CL6 the tick within two heartbeats completes (rc 0)" "0" "$(kv_of "$OUT" a_rc)"
_cl6_m="$(kv_of "$OUT" m6)"
[[ $_cl6_m =~ ^[0-9]+$ ]] && [ "$_cl6_m" -gt "$CL_OLD" ] \
    && pass "CL6 the tick within two heartbeats writes the sample" \
    || fail "CL6 the tick within two heartbeats did not write the sample" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL6 the sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
assert_eq "CL6 the tick within two heartbeats releases its claim" "0" "$(kv_of "$OUT" claim)"
assert_eq "CL6 no load/sample.new.* temp file is left" "0" "$(kv_of "$OUT" tmp)"
case_ran CL6

# ── CL8 / CL9 the deadline passes after the sample write, before the release ──
# Clock seam: _thl_now is frozen at the driver's start plus a skew file; a wrapper around
# _thl_sample_write sets the skew only after the write returns, so only the release check sees it.
# clock.log records each clock read's skew and "w" at the write, proving the pre-write check saw 0.
# CL8 skew 5 (> two heartbeats, < three): the sample stays written, the claim stays held.
# CL9 skew 4 (exactly two heartbeats): still valid, so the claim is released.
cl_late_tick() {
    C="$(new_cache)"; mk_slot "$C" 1 "$LIVE_SLEEP"; ls_run "$C"
    CL_S="$(new_snaps)"; CL_CK="$(new_snaps)"
    snap2 "$CL_S/snap.1" 222222 1000000 "$ROOT_PID 1 500 10240 bash"
    CL_OLD="$(($(now_epoch) - 10))"
    mk_sample "$C" "$CL_OLD" 0 0
    load_drv "$C" "$CL_S" "CK=$CL_CK" "SKEWV=$1" -- '
L="$THL_CACHE_ROOT/load"
cp "$L/sample" "$THL_CACHE_ROOT/sample.before"
(
    printf -v base "%(%s)T" -1
    _thl_now() {
        local s=0
        [ -f "$CK/skew" ] && read -r s < "$CK/skew"
        printf "%s\n" "$s" >> "$CK/clock.log"
        THL_NOW=$((base + s))
    }
    eval "_cl_orig_write() $(declare -f _thl_sample_write | tail -n +2)"
    _thl_sample_write() {
        local r=0
        _cl_orig_write "$@" || r=$?
        printf "w\n" >> "$CK/clock.log"; printf "%s\n" "$SKEWV" > "$CK/skew"
        return "$r"
    }
    thl_load_tick; echo "a_rc=$?"
    printf "a_token=%s\n" "${_THL_CLAIM_TOKEN:-}"
)
echo "seq=$(tr "\n" " " < "$CK/clock.log")"
o=""; { IFS= read -r o < "$L/.claim/owner"; } 2>/dev/null; echo "owner_token=$o"
cmp -s "$THL_CACHE_ROOT/sample.before" "$L/sample" && echo "same=1" || echo "same=0"
echo "m=$(ls_key measured_at)"; echo "schema=$(ls_key schema)"
_thl_sample_read "$L/sample"; echo "f_ok=$?"
[ -e "$L/.claim/owner" ] && echo "owner=1" || echo "owner=0"
[ -d "$L/.claim" ] && echo "claim=1" || echo "claim=0"
echo "tmp=$(ls -A "$L" | grep -c "^sample\.new\.")"'
}
# cl_late_common <id> <skew> — the assertions CL8 and CL9 share.
cl_late_common() {
    local seq m
    seq="$(kv_of "$OUT" seq)"
    [[ $seq == *" 0 w $2 " || $seq == "0 w $2 " ]] \
        && pass "$1 positive control: the pre-write check read no skew, the release check read $2 (seq: $seq)" \
        || fail "$1 the clock seam did not apply the skew only after the write" "seq=$(printf '%q' "$seq") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    assert_eq "$1 the tick completes (rc 0)" "0" "$(kv_of "$OUT" a_rc)"
    assert_eq "$1 the tick wrote load/sample (content differs from before)" "0" "$(kv_of "$OUT" same)"
    m="$(kv_of "$OUT" m)"
    [[ $m =~ ^[0-9]+$ ]] && [ "$m" -ne "$CL_OLD" ] \
        && pass "$1 the written sample carries a new measured_at" \
        || fail "$1 measured_at was not updated" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    assert_eq "$1 the written sample is schema 2" "2" "$(kv_of "$OUT" schema)"
    assert_eq "$1 the written sample is well-formed" "0" "$(kv_of "$OUT" f_ok)"
    assert_eq "$1 no load/sample.new.* temp file is left" "0" "$(kv_of "$OUT" tmp)"
}

cl_late_tick 5
cl_late_common CL8 5
_cl8_tok="$(kv_of "$OUT" a_token)"
[[ -n $_cl8_tok && $_cl8_tok == "$(kv_of "$OUT" owner_token)" ]] \
    && pass "CL8 load/.claim/owner is still this tick's token" \
    || fail "CL8 load/.claim/owner is not this tick's token" "out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
assert_eq "CL8 past two heartbeats at the release check, load/.claim/owner is kept" "1" "$(kv_of "$OUT" owner)"
assert_eq "CL8 past two heartbeats at the release check, load/.claim is kept" "1" "$(kv_of "$OUT" claim)"
case_ran CL8

cl_late_tick 4
cl_late_common CL9 4
assert_eq "CL9 at exactly two heartbeats, load/.claim/owner is released" "0" "$(kv_of "$OUT" owner)"
assert_eq "CL9 at exactly two heartbeats, load/.claim is released" "0" "$(kv_of "$OUT" claim)"
case_ran CL9

case_end

grp_done claim-cases.sh
