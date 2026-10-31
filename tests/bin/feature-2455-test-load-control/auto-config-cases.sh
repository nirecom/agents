#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/auto-config-cases.sh — AC1-AC3, AC7, AC8 (#2687 ②).
# AUTO_CONFIG_TEST_MAX_JOBS resolution, the off/on max-jobs-per-host rules, the unlimited
# max jobs per run on the not-applied path, and the retired never-ask record. Relies on
# lanes-cases.sh (L12_HID, L_OS_NOW, l12_conf) and run-all-lease-cases.sh (the runner
# fixture: r_reset, r_root, R_OUT, R_ERR, FX_CACHE_DIR, fx_exec, fx_peak_of, fx_peak_log).

AC_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
AC_MODE='run_all_auto_config; echo "m=${RUN_ALL_AUTO_CONFIG-}"'
AC_MAX='thl_max_jobs_per_host; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"; echo "a=${THL_AUTO_CONFIG-}"'
AC_PLAN='thl_plan 2; echo "note=${THL_NOTE-}"'
AC_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "note=${THL_NOTE-}"; thl_release_all'

# dotenv_multi NAME=VAL... — sets DOTENV_STUB to a resolver answering each NAME with its VAL
# (printed, never evaluated) and logging every asked name to <stub>.called.
dotenv_multi() {
    local nv body=""
    DOTENV_N=$((DOTENV_N + 1))
    DOTENV_STUB="$TMPDIR_BASE/dotenv-multi-$DOTENV_N.sh"
    for nv in "$@"; do
        body="$body$(printf '    %q) printf "%%s\\n" %q ;;' "${nv%%=*}" "${nv#*=}")"$'\n'
    done
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> %q\ncase "$1" in\n%s    *) ;;\nesac\nexit 0\n' \
        "$DOTENV_STUB.called" "$body" > "$DOTENV_STUB"
    chmod +x "$DOTENV_STUB"
}
# ac_asked <name> — 0 when the last stub was asked for <name>.
ac_asked() { grep -qxF -- "$1" "$DOTENV_STUB.called" 2>/dev/null; }
AC_E="$TMPDIR_BASE/ac-empty"; mkdir -p "$AC_E"

case_begin "auto-config-mode" "bin/lib/run-all-parallelism.sh"

# ── AC1 resolution env > .env > default on, case-insensitive ────────────────
lanes_drv "$AC_E" -- "$AC_MODE"
assert_eq "AC1 unset everywhere: on" "on" "$(kv_of "$OUT" m)"
dotenv_multi AUTO_CONFIG_TEST_MAX_JOBS=on
lanes_drv "$AC_E" AUTO_CONFIG_TEST_MAX_JOBS=off "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MODE"
assert_eq "AC1 env off beats .env on" "off" "$(kv_of "$OUT" m)"
ac_asked AUTO_CONFIG_TEST_MAX_JOBS && fail "AC1 a valid env value still launched the .env resolver" || pass "AC1 a valid env value launches no .env resolver"
dotenv_multi AUTO_CONFIG_TEST_MAX_JOBS=off
lanes_drv "$AC_E" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MODE"
assert_eq "AC1 .env off" "off" "$(kv_of "$OUT" m)"
ac_asked AUTO_CONFIG_TEST_MAX_JOBS && pass "AC1 the .env resolver was asked for AUTO_CONFIG_TEST_MAX_JOBS (positive control)" || fail "AC1 the .env resolver was never asked"
dotenv_multi AUTO_CONFIG_TEST_MAX_JOBS=OFF
lanes_drv "$AC_E" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MODE"
assert_eq "AC1 .env OFF (upper case)" "off" "$(kv_of "$OUT" m)"
dotenv_multi AUTO_CONFIG_TEST_MAX_JOBS=off
lanes_drv "$AC_E" AUTO_CONFIG_TEST_MAX_JOBS=on "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MODE"
assert_eq "AC1 env on beats .env off" "on" "$(kv_of "$OUT" m)"
for _v in Off OFF oFf; do
    lanes_drv "$AC_E" "AUTO_CONFIG_TEST_MAX_JOBS=$_v" -- "$AC_MODE"
    assert_eq "AC1 env $_v is off" "off" "$(kv_of "$OUT" m)"
done
for _v in On ON; do
    lanes_drv "$AC_E" "AUTO_CONFIG_TEST_MAX_JOBS=$_v" -- "$AC_MODE"
    assert_eq "AC1 env $_v is on" "on" "$(kv_of "$OUT" m)"
done
# An invalid value: one fixed note that never echoes it, treated as on.
AC_PWN="$TMPDIR_BASE/ac-pwned"
for _v in maybe-zq7 "0ff" "\$(touch $AC_PWN)" "off;touch $AC_PWN"; do
    lanes_drv "$AC_E" "AUTO_CONFIG_TEST_MAX_JOBS=$_v" -- "$AC_MODE"
    assert_eq "AC1 env $(printf '%q' "$_v") is invalid: on" "on" "$(kv_of "$OUT" m)"
    _n="$(printf '%s\n' "$ERR" | grep -c 'AUTO_CONFIG_TEST_MAX_JOBS' || true)"
    assert_eq "AC1 env $(printf '%q' "$_v"): exactly one note naming the variable" "1" "$_n"
    case "$OUT$ERR" in
        *"$_v"*) fail "AC1 env $(printf '%q' "$_v"): the note echoes the value" ;;
        *) pass "AC1 env $(printf '%q' "$_v"): the value is never echoed" ;;
    esac
done
dotenv_multi "AUTO_CONFIG_TEST_MAX_JOBS=\$(touch $AC_PWN)"
lanes_drv "$AC_E" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MODE"
assert_eq "AC1 a hostile .env value is invalid: on" "on" "$(kv_of "$OUT" m)"
case "$ERR" in *"touch"*) fail "AC1 a hostile .env value is echoed" ;; *) pass "AC1 a hostile .env value is never echoed" ;; esac
[ ! -e "$AC_PWN" ] && pass "AC1 a hostile mode value is never executed" || fail "AC1 a hostile mode value was executed"
lanes_drv "$AC_E" -- "$AC_MODE"
assert_eq "AC1 a valid value leaves stderr empty" "" "$ERR"
case_ran AC1

case_end

case_begin "auto-config-max-jobs-per-host" "bin/lib/test-host-lanes.sh"

# ── AC2 off: pins only, the record is never read, no calibrate hint ─────────
AC2R="$TMPDIR_BASE/ac2-rec"; l12_conf "$AC2R" 16
lanes_drv "$AC2R" AUTO_CONFIG_TEST_MAX_JOBS=off -- "$AC_MAX"
assert_eq "AC2 off: a record of 16 is not read -> 4/default" "4/default" "$(kv_of "$OUT" b)"
assert_eq "AC2 off: THL_AUTO_CONFIG" "off" "$(kv_of "$OUT" a)"
lanes_drv "$AC2R" AUTO_CONFIG_TEST_MAX_JOBS=off TEST_MAX_JOBS_PER_HOST=6 -- "$AC_MAX"
assert_eq "AC2 off: env pin 6 -> 6/env (over the record of 16)" "6/env" "$(kv_of "$OUT" b)"
dotenv_multi TEST_MAX_JOBS_PER_HOST=6 AUTO_CONFIG_TEST_MAX_JOBS=off
lanes_drv "$AC2R" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MAX"
assert_eq "AC2 .env off with .env pin 6 -> 6/dotenv" "6/dotenv/off" "$(kv_of "$OUT" b)/$(kv_of "$OUT" a)"
run_status "$AC2R" AUTO_CONFIG_TEST_MAX_JOBS=off
assert_tokens "AC2 off: status line 1" "max_jobs_per_host=4 source=default mode=off" "$(first_line "$OUT")" recalibrate measured_on
for _snip in "$AC_PLAN" "$AC_LEASE"; do
    lanes_drv "$AC2R" AUTO_CONFIG_TEST_MAX_JOBS=off -- "$_snip"
    _note="$(kv_of "$OUT" note)"
    case "$_note" in
        *calibrat*|"") fail "AC2 off: the note carries a calibrate hint or is empty — note=$(printf '%q' "$_note")" ;;
        "jobs 2 of requested 2 (max jobs per host 4, source default"*) pass "AC2 off: the ${_snip%% *} note has no calibrate hint" ;;
        *) fail "AC2 off: unexpected note — note=$(printf '%q' "$_note")" ;;
    esac
done
AC2O="$TMPDIR_BASE/ac2-oldos"; l12_conf "$AC2O" 16 "${L_OS_NOW%%/*}/0.0.0-ac2"
lanes_drv "$AC2O" AUTO_CONFIG_TEST_MAX_JOBS=off -- "$AC_LEASE"
case "$(kv_of "$OUT" note)" in
    *"measured on"*|*re-run*) fail "AC2 off: an OS-mismatched record still advises — note=$(printf '%q' "$(kv_of "$OUT" note)")" ;;
    *) pass "AC2 off: an OS-mismatched record raises no advice (never read)" ;;
esac
case_ran AC2

# ── AC3 on: effective = min(pin, base), source is the layer that set the min ─
AC3H="$TMPDIR_BASE/ac3-16"; l12_conf "$AC3H" 16
AC3L="$TMPDIR_BASE/ac3-8"; l12_conf "$AC3L" 8
AC3N="$TMPDIR_BASE/ac3-none"; mkdir -p "$AC3N"
dotenv_multi TEST_MAX_JOBS_PER_HOST=12
lanes_drv "$AC3H" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MAX"
assert_eq "AC3 on: .env pin 12 + measured 16 -> 12/dotenv" "12/dotenv/on" "$(kv_of "$OUT" b)/$(kv_of "$OUT" a)"
lanes_drv "$AC3L" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MAX"
assert_eq "AC3 on: .env pin 12 + measured 8 -> 8/measured" "8/measured" "$(kv_of "$OUT" b)"
lanes_drv "$AC3N" "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MAX"
assert_eq "AC3 on: .env pin 12 + no record -> 4/default" "4/default" "$(kv_of "$OUT" b)"
lanes_drv "$AC3H" TEST_MAX_JOBS_PER_HOST=12 -- "$AC_MAX"
assert_eq "AC3 on: env pin 12 + measured 16 -> 12/env" "12/env" "$(kv_of "$OUT" b)"
lanes_drv "$AC3N" TEST_MAX_JOBS_PER_HOST=4 -- "$AC_MAX"
assert_eq "AC3 on: a pin equal to the base reports the base (4/default)" "4/default" "$(kv_of "$OUT" b)"
AC3E="$TMPDIR_BASE/ac3-5"; l12_conf "$AC3E" 5
lanes_drv "$AC3E" TEST_MAX_JOBS_PER_HOST=5 -- "$AC_MAX"
assert_eq "AC3 on: pin 5 = record 5 reports measured" "5/measured" "$(kv_of "$OUT" b)"
dotenv_multi TEST_MAX_JOBS_PER_HOST=12
lanes_drv "$AC3H" TEST_MAX_JOBS_PER_HOST=3 "RUN_ALL_CONFIG_VAR_CMD=$DOTENV_STUB" -- "$AC_MAX"
assert_eq "AC3 on: env pin 3 beats .env pin 12 and the record" "3/env" "$(kv_of "$OUT" b)"
run_status "$AC3H" TEST_MAX_JOBS_PER_HOST=12
assert_tokens "AC3 on: status line 1" "max_jobs_per_host=12 source=env mode=on" "$(first_line "$OUT")" record
lanes_drv "$AC3N" -- "$AC_PLAN"
case "$(kv_of "$OUT" note)" in
    *"calibrate with $AC_HINT"*) pass "AC3 on: the default-source plan note keeps the calibrate hint" ;;
    *) fail "AC3 on: the default-source plan note lacks the calibrate hint — note=$(printf '%q' "$(kv_of "$OUT" note)")" ;;
esac
case_ran AC3

# ── AC8 a calibration-never-ask.conf left on disk is ignored, never deleted ──
AC8C="$TMPDIR_BASE/ac8-cache"; mkdir -p "$AC8C"
printf 'schema=1\nhost_id=%s\nrecorded_at=2026-01-01T00:00:00Z\n' "$L12_HID" > "$AC8C/calibration-never-ask.conf"
lanes_drv "$AC8C" -- "$AC_PLAN"
assert_eq "AC8 the default plan note keeps the calibrate hint despite a never-ask file" \
    "jobs 2 of requested 2 (max jobs per host 4, source default, record missing; calibrate with $AC_HINT; starts at up to 4 and grows per run-all lane allocation sample (slow start); re-evaluated at each entry-script end; running jobs are never stopped, so a run may hold more than its per-run lane cap until they finish)" \
    "$(kv_of "$OUT" note)"
lanes_drv "$AC8C" -- 'declare -F run_all_never_ask_active run_all_never_ask_write run_all_never_ask_file >/dev/null; echo "st=$?"'
assert_eq "AC8 the never-ask functions are gone from the lib" "1" "$(kv_of "$OUT" st)"
[ -f "$AC8C/calibration-never-ask.conf" ] && pass "AC8 the never-ask file is left on disk (not deleted)" || fail "AC8 the never-ask file was deleted"
case_ran AC8

case_end

case_begin "auto-config-runner" "tests/run-all.sh"

# ── AC7 lanes not applied + max jobs per run unlimited -> the lane pool ─────
AC7W="$(r_root 6 --peak --sleep 1)"
AC7_NOTE="(max jobs per run unlimited, bounded by the run-all lane pool)"
# ac7_plan <label> -- <runner args...> — --print-plan with H=3 and no TEST_MAX_JOBS_PER_RUN.
ac7_plan() {
    local label="$1" want="$2"; shift 2
    fx_exec "$AC7W" 60 "$R_OUT" "$R_ERR" --print-plan "$@" --all; _rc=$?
    assert_eq "AC7 $label: --print-plan exits 0" "0" "$_rc"
    assert_eq "AC7 $label: jobs=$want" "jobs=$want" "$(grep '^jobs=' "$R_OUT")"
}
for _mode in on off; do
    r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off; AUTO_CONFIG_TEST_MAX_JOBS="$_mode"
    ac7_plan "TEST_LANES=off, $_mode" 2
    grep -qF -- "jobs 2 $AC7_NOTE" "$R_ERR" && pass "AC7 TEST_LANES=off, $_mode: the plan says 'jobs 2 $AC7_NOTE'" \
        || fail "AC7 TEST_LANES=off, $_mode: the bounded note is missing — err=$(printf '%q' "$(cat "$R_ERR")")"
    grep -qF -- "max jobs per run: unlimited (default)" "$R_ERR" && pass "AC7 $_mode: max jobs per run is unlimited (default)" \
        || fail "AC7 $_mode: no 'max jobs per run: unlimited (default)' — err=$(printf '%q' "$(cat "$R_ERR")")"
done
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_HELD=123
ac7_plan "nested holder" 2
grep -qF -- "jobs 2 $AC7_NOTE" "$R_ERR" && pass "AC7 nested: the plan says 'jobs 2 $AC7_NOTE'" \
    || fail "AC7 nested: the bounded note is missing — err=$(printf '%q' "$(cat "$R_ERR")")"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
ac7_plan "explicit -j 5 stays 5" 5 -j 5
grep -qF -- "not applied (TEST_LANES=off); jobs 5 as requested" "$R_ERR" && pass "AC7 explicit -j 5: 'jobs 5 as requested'" \
    || fail "AC7 explicit -j 5: note — err=$(printf '%q' "$(cat "$R_ERR")")"
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES=off
fx_exec "$AC7W" 120 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "AC7 TEST_LANES=off run exits 0" "0" "$_rc"
_pk="$(fx_peak_of "$(fx_peak_log "$AC7W")")"
[[ "$_pk" =~ ^[12]$ ]] && pass "AC7 TEST_LANES=off run: peak $_pk <= the lane pool 2" || fail "AC7 TEST_LANES=off run: peak [$_pk] over the lane pool 2"
r_reset
case_ran AC7

case_end

case_begin "never-ask-calibrator-print" "bin/calibrate-test-parallelism.sh"

# ── AC8 calibrate --print still advises with a never-ask file present ───────
AC8P="$TMPDIR_BASE/ac8-print"; mkdir -p "$AC8P" "$TMPDIR_BASE/ac8-home" "$TMPDIR_BASE/ac8-tmp"
AC8_OLD="${L_OS_NOW%%/*}"; AC8_OLD="${AC8_OLD:-Unknown}/0.0.0-ac8"
l12_conf "$AC8P" 3 "$AC8_OLD"
cp "$AC8C/calibration-never-ask.conf" "$AC8P/"
_rc=0
"$RUN_TIMEOUT" 60 env -u RUN_ALL_PARALLELISM_LIB -u TEST_MAX_JOBS_PER_HOST -u RUN_CALIBRATION -u AUTO_CONFIG_TEST_MAX_JOBS \
    "HOME=$TMPDIR_BASE/ac8-home" "TMPDIR=$TMPDIR_BASE/ac8-tmp" "RUN_ALL_CACHE_DIR=$AC8P" \
    "RUN_ALL_CONFIG_VAR_CMD=$NO_CONFIG_VAR_CMD" "PATH=$CPU_SHIM_DIR:$PATH" \
    bash "$CALIBRATOR" --print >"$TMPDIR_BASE/ac8.out" 2>"$TMPDIR_BASE/ac8.err" || _rc=$?
assert_eq "AC8 --print exits 0" "0" "$_rc"
grep -qF -- "os=$AC8_OLD" "$TMPDIR_BASE/ac8.out" && pass "AC8 --print reports the record's os" || fail "AC8 --print stdout=$(printf '%q' "$(cat "$TMPDIR_BASE/ac8.out")")"
grep -qxF -- "calibrate: measured on $AC8_OLD, now $L_OS_NOW; re-run $AC_HINT" "$TMPDIR_BASE/ac8.err" \
    && pass "AC8 --print carries the full re-run advice despite a never-ask file" \
    || fail "AC8 --print lacks the advice — stderr=$(printf '%q' "$(cat "$TMPDIR_BASE/ac8.err")")"
case_ran AC8

case_end

grp_done auto-config-cases.sh
