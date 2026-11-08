#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/lanes-limits-cases.sh — L14-L18, LS1-LS5.
# Invalid limits, not-applied leases, heartbeat stop, reclaim tokens, malformed owners and
# the bin/test-lanes-status.sh CLI. Split from lanes-cases.sh (HARD line limit, and so the
# two halves run as separate run-all entries). Relies on _lanes-fixture.sh.

case_begin "host-lanes-limits" "bin/lib/test-host-lanes.sh"

# ── L14 an invalid limit skips its layer with one fixed notice ──────────────
L14N="$TMPDIR_BASE/l14-nocache"
L14K="$TMPDIR_BASE/l14-cal"
L14M="$TMPDIR_BASE/l14-pwned"
l12_conf "$L14K" 5
L14_RUNALL='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; thl_release_all'
# l14_notice <label> <raw-value> <want-lines> — stderr carries exactly <want-lines>
# notice lines, none of which echoes a raw value of 3+ characters back.
l14_notice() {
    local n
    n="$(printf '%s\n' "$ERR" | grep -c . || true)"
    if ! no_shell_error "$ERR"; then
        fail "L14 $1: shell error instead of a notice: $(printf '%q' "$ERR")"
    elif [ "$n" != "$3" ]; then
        fail "L14 $1: want $3 notice line(s) on stderr, got $n: $(printf '%q' "$ERR")"
    elif [ "$3" = 1 ] && [ "${#2}" -ge 3 ] && printf '%s' "$ERR" | grep -qF -- "$2"; then
        fail "L14 $1: the notice echoes the raw value: $(printf '%q' "$ERR")"
    else
        pass "L14 $1: $3 fixed notice line(s) on stderr"
    fi
}
# Column 6 pins AUTO_CONFIG_TEST_MAX_JOBS for the row (empty: unset, the on default).
while IFS='|' read -r _var _val _cache _want _nl _am; do
    [ -n "$_var" ] || continue
    _m=(); [ -z "$_am" ] || _m=("AUTO_CONFIG_TEST_MAX_JOBS=$_am")
    if [ "$_var" = "TEST_MAX_JOBS_PER_HOST" ]; then
        lanes_drv "$_cache" ${_m[@]+"${_m[@]}"} "$_var=$_val" -- "$L12_SNIP" </dev/null
        assert_eq "L14 $_var=$_val: resolves to $_want" "$_want" "$(kv_of "$OUT" b)"
        l14_notice "$_var=$_val" "$_val" "$_nl"
    elif [ "$_var" = "DOTENV" ]; then
        dotenv_stub TEST_MAX_JOBS_PER_HOST "$_val"
        lanes_drv "$_cache" ${_m[@]+"${_m[@]}"} "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$L12_SNIP" </dev/null
        assert_eq "L14 .env TEST_MAX_JOBS_PER_HOST=$(printf '%q' "$_val"): resolves to $_want" "$_want" "$(kv_of "$OUT" b)"
        l14_notice ".env value $(printf '%q' "$_val")" "$_val" "$_nl"
    else
        rm -rf "$_cache/slots"
        _snip="$LEASE_SNIP"'; thl_release_all'
        [ "$_var" = "TEST_LANES_HEARTBEAT" ] && _snip="$L14_RUNALL"
        lanes_drv "$_cache" TEST_MAX_JOBS_PER_HOST=2 "$_var=$_val" -- "$_snip" </dev/null
        assert_eq "L14 $_var=$_val: the lease does not abort (rc 0)" "0" "$(kv_of "$OUT" rc)"
    fi
    no_shell_error "$ERR" && pass "L14 $_var=$_val: no shell evaluation error" || fail "L14 $_var=$_val: shell error on stderr: $(printf '%q' "$ERR")"
done <<L14ROWS
TEST_MAX_JOBS_PER_HOST|0|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|abc|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|-1|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|1025|$L14N|4/default|1
TEST_MAX_JOBS_PER_HOST|0|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|abc|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|-1|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|1025|$L14K|5/measured|1
TEST_MAX_JOBS_PER_HOST|1|$L14K|1/env|0
TEST_MAX_JOBS_PER_HOST|1024|$L14N|1024/env|0|off
TEST_MAX_JOBS_PER_HOST|1024|$L14N|4/default|0|on
DOTENV|abc|$L14K|5/measured|1
DOTENV|0|$L14K|5/measured|1
DOTENV|1025|$L14N|4/default|1
DOTENV|\$(touch $L14M)|$L14K|5/measured|1
DOTENV|1024|$L14N|1024/dotenv|0|off
TEST_LANES_WAIT_CAP|abc|$L14N|-|-
TEST_LANES_WAIT_INTERVAL|abc|$L14N|-|-
TEST_LANES_TTL|abc|$L14N|-|-
TEST_LANES_HEARTBEAT|abc|$L14N|-|-
L14ROWS
[ ! -e "$L14M" ] && pass "L14 a .env payload is data, never evaluated (marker absent)" || fail "L14 a .env value was evaluated as code"
case_ran L14

# ── L15 thl_run_all_lease honours TEST_LANES=off and a nested holder ────────
for _mode in "TEST_LANES=off" "TEST_LANES_HELD=123"; do
    _c="$TMPDIR_BASE/l15-cache-${_mode%%=*}"
    lanes_drv "$_c" TEST_MAX_JOBS_PER_HOST=3 "$_mode" -- 'thl_init_dir; thl_run_all_lease 8 0; echo "rc=$?"; echo "granted=${THL_GRANTED:-unset}"; echo "held=${TEST_LANES_HELD-unset}"; echo "note=${THL_NOTE-}"'
    assert_eq "L15 $_mode: thl_run_all_lease returns 0" "0" "$(kv_of "$OUT" rc)"
    if [ "$_mode" = "TEST_LANES=off" ]; then _why="TEST_LANES=off"; else _why="nested under a lane holder"; fi
    assert_eq "L15 $_mode: THL_NOTE names why the limit is not applied" "not applied ($_why); jobs 8 as requested" "$(kv_of "$OUT" note)"
    [ ! -e "$_c/slots" ] && pass "L15 $_mode: no slots/ directory" || fail "L15 $_mode: slots/ was created ($(lane_names "$_c"))"
    case "$(kv_of "$OUT" granted)" in
        unset|8) pass "L15 $_mode: -j is not truncated (granted=$(kv_of "$OUT" granted))" ;;
        *) fail "L15 $_mode: the grant truncates -j 8 (granted=$(kv_of "$OUT" granted))" ;;
    esac
done
assert_eq "L15 TEST_LANES_HELD=123: the nested marker is left untouched" "123" "$(kv_of "$OUT" held)"
case_ran L15

# ── L16 released heartbeat is really stopped (token-matched probe) ──────────
L16C="$TMPDIR_BASE/l16-cache"
lanes_drv "$L16C" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_HEARTBEAT=1 -- "$HB_WAIT_FN"'
thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"
d="$THL_CACHE_ROOT/slots/lane.1"
printf "1000\n" > "$d/hb"; hb_wait_refresh "$d/hb" 3; echo "hb_live=$(cat "$d/hb")"
cp "$d/owner" "$THL_CACHE_ROOT/owner.save"
thl_release_all
mkdir -p "$d"; cp "$THL_CACHE_ROOT/owner.save" "$d/owner"; printf "1000\n" > "$d/hb"
sleep 3; echo "hb_after=$(cat "$d/hb")"; rm -rf "$d"'
assert_eq "L16 run-all lease precondition" "0" "$(kv_of "$OUT" rc)"
_hb="$(kv_of "$OUT" hb_live)"
[[ "$_hb" =~ ^[0-9]+$ ]] && [ "$_hb" -gt 1000 ] && pass "L16 positive control: the heartbeat refreshes a held lane" || fail "L16 heartbeat never refreshed the held lane (hb=[$_hb])"
assert_eq "L16 after thl_release_all a lane re-created with the SAME token keeps hb=1000" "1000" "$(kv_of "$OUT" hb_after)"
case_ran L16

# ── L17 a reclaimed lane carries the new holder's token, no grave left ──────
L17C="$TMPDIR_BASE/l17-cache"
mk_slot "$L17C" 1 "$(dead_pid)" "$OSTYPE" run-all "" "9.9.9"
lanes_drv "$L17C" TEST_MAX_JOBS_PER_HOST=1 -- "$LEASE_SNIP"'
echo "tok=$(sed -n "s/^token=//p" "$THL_CACHE_ROOT/slots/lane.1/owner" 2>/dev/null)"; echo "mytok=${THL_TOKEN-}"
g=0; for d in "$THL_CACHE_ROOT"/slots/.grave.*; do [ -e "$d" ] && g=$((g+1)); done; echo "graves=$g"
thl_release_all'
assert_eq "L17 dead holder reclaimed (rc 0)" "0" "$(kv_of "$OUT" rc)"
_tok="$(kv_of "$OUT" tok)"
if [ -n "$_tok" ] && [ "$_tok" != "9.9.9" ] && [ "$_tok" = "$(kv_of "$OUT" mytok)" ] && [ "${_tok%%.*}" = "$(kv_of "$OUT" drvpid)" ]; then
    pass "L17 lane.1 owner token is the new holder's ($_tok)"
else
    fail "L17 lane.1 owner token not rewritten — tok=[$_tok] THL_TOKEN=[$(kv_of "$OUT" mytok)] drvpid=[$(kv_of "$OUT" drvpid)]"
fi
assert_eq "L17 no slots/.grave.* left after the reclaim" "0" "$(kv_of "$OUT" graves)"
case_ran L17

# ── L18 malformed owner/hb fields are data, never code ──────────────────────
L18C="$TMPDIR_BASE/l18-cache"
L18M="$TMPDIR_BASE/l18-pwned"
mk_slot "$L18C" 1 "$LIVE_PID"; printf 'abc\n' > "$L18C/slots/lane.1/hb"
mk_slot "$L18C" 2 "$LIVE_PID"; printf 'a[$(touch %s)]\n' "$L18M" > "$L18C/slots/lane.2/hb"
mkdir -p "$L18C/slots/lane.3"
printf 'pid=a[$(touch %s)]\nenv=%s\nkind=run-all\nstart=a[$(touch %s)]\ntoken=x\n' "$L18M" "$OSTYPE" "$L18M" > "$L18C/slots/lane.3/owner"
printf 'a[$(touch %s)]\n' "$L18M" > "$L18C/slots/lane.3/hb"
mkdir -p "$L18C/slots/lane.4"; : > "$L18C/slots/lane.4/owner"
run_status "$L18C" TEST_MAX_JOBS_PER_HOST=4
assert_eq "L18 test-lanes-status survives malformed owners (exit 0)" "0" "$RC"
no_shell_error "$ERR" && pass "L18 status: no shell evaluation error" || fail "L18 status stderr: $(printf '%q' "$ERR")"
lanes_drv "$L18C" TEST_MAX_JOBS_PER_HOST=4 TEST_LANES_WAIT_CAP=2 -- "$LEASE_SNIP"'; thl_release_all'
case "$(kv_of "$OUT" rc)" in
    0|4) pass "L18 lease completes on malformed owners (rc $(kv_of "$OUT" rc))" ;;
    *) fail "L18 lease crashed on malformed owners — drv rc=$RC lease rc=[$(kv_of "$OUT" rc)] err=$(printf '%q' "$ERR")" ;;
esac
no_shell_error "$ERR" && pass "L18 lease: no shell evaluation error" || fail "L18 lease stderr: $(printf '%q' "$ERR")"
[ ! -e "$L18M" ] && pass "L18 no owner/hb payload was evaluated (marker absent)" || fail "L18 a malformed owner/hb field was evaluated as code"
case_ran L18

case_end

case_begin "lanes-status-cli" "bin/test-lanes-status.sh"

# ── LS1 empty ───────────────────────────────────────────────────────────────
run_status "$TMPDIR_BASE/ls1-cache" TEST_MAX_JOBS_PER_HOST=2
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'no test lanes held'; then
    pass "LS1 no slots: 'no test lanes held', exit 0"
else
    fail "LS1 empty status — rc=$RC out=$(printf '%q' "$OUT")"
fi
# On mode (the default): a pin below the default 4 wins as the min, so its layer is the source.
assert_tokens "LS1 env source: first line" "max_jobs_per_host=2 source=env mode=on" "$(first_line "$OUT")" record capped logical_cpus
run_status "$TMPDIR_BASE/ls1-default"
assert_tokens "LS1 no record: first line names the default and the record's reason" \
    "max_jobs_per_host=4 source=default record=missing mode=on" "$(first_line "$OUT")" capped logical_cpus
dotenv_stub TEST_MAX_JOBS_PER_HOST 3
run_status "$TMPDIR_BASE/ls1-dotenv" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB"
assert_tokens "LS1 .env source: first line" "max_jobs_per_host=3 source=dotenv mode=on" "$(first_line "$OUT")" record capped
case_ran LS1

# ── LS2 every state, read-only ──────────────────────────────────────────────
LS2C="$TMPDIR_BASE/ls2-cache"
mk_slot "$LS2C" 1 "$LIVE_PID"
mk_slot "$LS2C" 2 "$(dead_pid)"
mk_slot "$LS2C" 3 "$LIVE_PID" "$OSTYPE" run-all "$(( $(now_epoch) - 700 ))"
mk_slot "$LS2C" 4 "$(dead_pid)" other-env
mk_slot "$LS2C" 5 ""
# #2692: a presence row has 10 columns (allocation columns `-` with no sample); lane rows keep 6.
_r="$LS2C/runs/run.$LIVE_PID.1.1"; mkdir -p "$_r"; now_epoch > "$_r/hb"; printf 'pid=%s\nenv=%s\nkind=run-all\nstart=1\ntoken=%s.1.1\n' "$LIVE_PID" "$OSTYPE" "$LIVE_PID" > "$_r/owner"
run_status "$LS2C" TEST_MAX_JOBS_PER_HOST=5 AUTO_CONFIG_TEST_MAX_JOBS=off
assert_eq "LS2 status exits 0" "0" "$RC"
assert_tokens "LS2 first line is max_jobs_per_host=<N> source=<...>" "max_jobs_per_host=5 source=env mode=off" "$(first_line "$OUT")"
_i=0
for _st in alive stale-dead-pid stale-ttl foreign ownerless; do
    _i=$((_i + 1))
    if printf '%s\n' "$OUT" | grep -qE "^(lane\.)?$_i"$'\t'".*"$'\t'"$_st\$"; then
        pass "LS2 lane $_i reported as $_st"
    else
        fail "LS2 lane $_i not reported as $_st — out=$(printf '%q' "$OUT")"
    fi
done
assert_eq "LS2 status is read-only (all five lanes still present)" "lane.1 lane.2 lane.3 lane.4 lane.5" "$(lane_names "$LS2C")"
assert_eq "LS2 presence row: 10 columns, '-' allocation; lane rows: 6 columns" "run:10:- - - - lane:6" \
    "$(printf '%s\n' "$OUT" | awk -F'\t' '/^run\./ { r = "run:" NF ":" $7 " " $8 " " $9 " " $10 } /^lane\./ { l[NF] = 1 } END { for (n in l) r = r " lane:" n; print r }')"
run_status "$LS2C" -- --bogus
assert_eq "LS2 --bogus is a usage error (exit 2)" "2" "$RC"
case_ran LS2

# ── LS3 allow-listed and executable ─────────────────────────────────────────
grep -qxF 'bin/test-lanes-status.sh' "$ALLOW_TXT" && pass "LS3 install/settings-allow-commands.txt lists bin/test-lanes-status.sh" || fail "LS3 bin/test-lanes-status.sh missing from the allow list"
_mode="$(git -C "$AGENTS_ROOT" ls-files -s -- bin/test-lanes-status.sh 2>/dev/null | cut -d' ' -f1)"
if [ "$_mode" = "100755" ] || { [ -z "$_mode" ] && [ -x "$STATUS_CLI" ] && [ -f "$STATUS_CLI" ]; }; then
    pass "LS3 bin/test-lanes-status.sh is executable (mode=${_mode:-worktree -x})"
else
    fail "LS3 bin/test-lanes-status.sh is not executable (index mode=[${_mode}] exists=$([ -f "$STATUS_CLI" ] && echo yes || echo no))"
fi
case_ran LS3

# ── LS4 -h / --help is a successful usage print, not a usage error ──────────
for _h in -h --help; do
    run_status "$TMPDIR_BASE/ls4-cache" -- "$_h"
    assert_eq "LS4 bin/test-lanes-status.sh $_h exits 0" "0" "$RC"
done
[ ! -e "$TMPDIR_BASE/ls4-cache/slots" ] && pass "LS4 --help creates no slots/" || fail "LS4 --help created slots/"
case_ran LS4

# ── LS5 a record measured on another OS version keeps its value and advises ─
if [[ "$L_OS_NOW" =~ ^[A-Za-z0-9._-]{1,32}/[A-Za-z0-9._-]{1,64}$ ]]; then
    pass "LS5 precondition: run_all_os_attr yields <kind>/<version> ($L_OS_NOW)"
else
    fail "LS5 precondition: run_all_os_attr missing or malformed [$L_OS_NOW]"
fi
LS5_KIND="${L_OS_NOW%%/*}"; [ -n "$LS5_KIND" ] || LS5_KIND="Unknown"
LS5_OLD="$LS5_KIND/0.0.0-ls5"
LS5_ADVICE="measured on $LS5_OLD, now $L_OS_NOW; re-run RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
LS5_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"; echo "note=${THL_NOTE-}"; thl_release_all'
LS5D="$TMPDIR_BASE/ls5-diff"
l12_conf "$LS5D" 5 "$LS5_OLD"
run_status "$LS5D"
assert_tokens "LS5 os differs: status first line keeps the record and names both versions" \
    "max_jobs_per_host=5 source=measured measured_on=$LS5_OLD now=$L_OS_NOW mode=on" "$(first_line "$OUT")" recalibrate
lanes_drv "$LS5D" -- "$LS5_LEASE"
assert_eq "LS5 os differs: the lease succeeds" "0" "$(kv_of "$OUT" rc)"
assert_eq "LS5 os differs: the limit is the record's value, not invalidated" "5/measured" "$(kv_of "$OUT" b)"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    "jobs 2 of requested 2 (max jobs per host 5, source measured; lanes "*"; $LS5_ADVICE"*)
        pass "LS5 os differs: the lanes: note carries the advice" ;;
    *) fail "LS5 os differs: lanes: note lacks the grant or the advice — note=$(printf '%q' "$_note")" ;;
esac
LS5S="$TMPDIR_BASE/ls5-same"
l12_conf "$LS5S" 5
run_status "$LS5S"
assert_tokens "LS5 same os: status first line carries no measured_on/now" "max_jobs_per_host=5 source=measured mode=on" "$(first_line "$OUT")" measured_on now recalibrate capped
lanes_drv "$LS5S" -- "$LS5_LEASE"
assert_eq "LS5 same os: the limit is the record's value" "5/measured" "$(kv_of "$OUT" b)"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    *"measured on"*|*re-run*|*calibrate*|"") fail "LS5 same os: note missing or carries an advice — note=$(printf '%q' "$_note")" ;;
    "jobs 2 of requested 2 (max jobs per host 5, source measured; lanes 1 2)"*) pass "LS5 same os: the lanes: note has no advice" ;;
    *) fail "LS5 same os: unexpected note format — note=$(printf '%q' "$_note")" ;;
esac
lanes_drv "$TMPDIR_BASE/ls5-none" -- "$LS5_LEASE"
_note="$(kv_of "$OUT" note)"
case "$_note" in
    "jobs 2 of requested 2 (max jobs per host 4, source default"*missing*calibrate-test-parallelism*)
        pass "LS5 default source: the lanes: note names the record reason and the calibrator" ;;
    *) fail "LS5 default source: note lacks the reason token or the calibrator — note=$(printf '%q' "$_note")" ;;
esac
case_ran LS5

case_end

grp_done lanes-limits-cases.sh
