#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/run-all-grant-cases.sh — R8-R13.
# The calibrator opt-out, the no-lanes-lib path, the reserved find-tests lane, the
# not-applied notice, the partial grant and the OS-version advice. Split from
# run-all-lease-cases.sh so the two halves run as separate run-all entries.
# Relies on _runner-fixture.sh.

case_begin "run-all-grant" "tests/run-all.sh"

# ── R8 the calibrator opts out of lanes ─────────────────────────────────────
grep -qF 'export TEST_LANES=off' "$CALIBRATOR" && pass "R8 calibrator exports TEST_LANES=off" || fail "R8 bin/calibrate-test-parallelism.sh lacks 'export TEST_LANES=off'"
case_ran R8

# ── R9 no lanes lib: unchanged -j ───────────────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3
R9="$(FX_WITH_LANES=0 r_root 6 --peak --sleep 1)"
fx_exec "$R9" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R9 run without the lanes lib exits 0" "0" "$_rc"
r_has_lanes_line && fail "R9 a lanes: line appeared without the lanes lib" || pass "R9 no lanes: line without the lanes lib"
_pk="$(fx_peak_of "$(fx_peak_log "$R9")")"
[ "$_pk" -ge 3 ] && pass "R9 -j is not capped without the lanes lib (peak $_pk >= 3)" || fail "R9 peak $_pk < 3 — -j was capped without the lanes lib"
case_ran R9

# ── R10 lane N is reserved for find-tests ───────────────────────────────────
r_reset; TEST_MAX_JOBS_PER_HOST=3; TEST_LANES_WAIT_CAP=6; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"; mk_slot "$FX_CACHE_DIR" 2 "$$"
R10="$(r_root 1)"
R10_OUT="$FX_TMP_ROOT/r10.out"; R10_ERR="$FX_TMP_ROOT/r10.err"
fx_exec_bg "$R10" "$R10_OUT" "$R10_ERR" --all
_bg="$FX_BG_PID"
# Fixed on purpose: the waiting run-all must have polled lane.3 before the negative check.
sleep 2
[ -e "$FX_CACHE_DIR/slots/lane.3" ] && fail "R10 the waiting run-all took the reserved lane.3" || pass "R10 the waiting run-all leaves lane.3 free"
R10R="$(mk_repo)"; add_tf "$R10R" bin/a.sh "src/x.js"; commit_all "$R10R" c
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$FX_CACHE_DIR" TEST_MAX_JOBS_PER_HOST=3 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 -- --root "$R10R" --sources src/x.js
assert_eq "R10 find-tests takes lane.3 and succeeds meanwhile" "0" "$RC"
r_wait_gone 30 "$_bg" || fx_kill_tree "$_bg"
wait "$_bg" 2>/dev/null; _rc=$?
assert_eq "R10 the second run-all exits 4 at its cap (never used lane.3)" "4" "$_rc"
r_reset; TEST_MAX_JOBS_PER_HOST=1; TEST_LANES_WAIT_CAP=3
R10B="$(r_root 1)"
fx_exec "$R10B" 60 "$R_OUT" "$R_ERR" --all; _rc=$?
assert_eq "R10 N=1: run-all runs on lane.1 (rc 0)" "0" "$_rc"
r_has_lanes_line && pass "R10 N=1: the run was leased (lanes: line)" || fail "R10 N=1: no lanes: line — lane.1 not leased"
[[ "$(r_lanes_line)" =~ ^jobs\ 1\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 1,\ source\ env\;\ lanes\ 1\) ]] \
    && pass "R10 N=1: lanes: line reports lane 1 of max jobs per host 1" \
    || fail "R10 N=1: lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
case_ran R10

# ── R11 TEST_LANES=off and a nested holder: a not-applied notice, -j untouched ─
for _mode in off held; do
    r_reset; TEST_MAX_JOBS_PER_HOST=3
    if [ "$_mode" = off ]; then TEST_LANES=off; _why="TEST_LANES=off"; else TEST_LANES_HELD=123; _why="nested under a lane holder"; fi
    R11="$(r_root 6 --peak --sleep 1)"
    fx_exec "$R11" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
    assert_eq "R11 $_mode: run exits 0" "0" "$_rc"
    [[ "$(r_lanes_line)" =~ ^not\ applied\ \($_why\)\;\ jobs\ [0-9]+\ as\ requested$ ]] \
        && pass "R11 $_mode: lanes: line says 'not applied ($_why); jobs <n> as requested'" \
        || fail "R11 $_mode: lanes: not-applied notice — got $(printf '%q' "$(r_lanes_line)")"
    _pk="$(fx_peak_of "$(fx_peak_log "$R11")")"
    [ "$_pk" -ge 3 ] && pass "R11 $_mode: -j 8 is not capped at N-1 (peak $_pk >= 3)" || fail "R11 $_mode: peak $_pk < 3 — -j was capped"
    assert_eq "R11 $_mode: no lane created" "" "$(lane_names "$FX_CACHE_DIR")"
done
case_ran R11

# ── R12 partial grant: lane.1 busy, N=4 -j 8 runs on the two free lanes ─────
# Mode off pins the env layer as the source: under on, a pin equal to the default 4 reports `default`.
r_reset; TEST_MAX_JOBS_PER_HOST=4; AUTO_CONFIG_TEST_MAX_JOBS=off; TEST_LANES_WAIT_CAP=3; TEST_LANES_WAIT_INTERVAL=1
mk_slot "$FX_CACHE_DIR" 1 "$$"
R12="$(r_root 6 --peak --sleep 1)"
fx_exec "$R12" 120 "$R_OUT" "$R_ERR" -j 8 --all; _rc=$?
assert_eq "R12 run starts on a partial grant and exits 0" "0" "$_rc"
r_has_lanes_line && pass "R12 stderr carries a lanes: line" || fail "R12 no lanes: line — the run was not leased"
[[ "$(r_lanes_line)" =~ ^jobs\ 2\ of\ requested\ [0-9]+\ \(max\ jobs\ per\ host\ 4,\ source\ env\;\ lanes\ 2\ 3\;\ slow\ start\ from\ 2,\ grows\ per\ run-all\ lane\ allocation\ sample\) ]] \
    && pass "R12 lanes: line reports the partial grant on lanes 2 3 with its slow start" \
    || fail "R12 lanes: line format — got $(printf '%q' "$(r_lanes_line)")"
assert_eq "R12 N=4 with lane.1 busy: peak concurrency is the 2 granted lanes" "2" "$(fx_peak_of "$(fx_peak_log "$R12")")"
assert_eq "R12 the busy lane.1 is untouched and nothing else is left" "lane.1" "$(lane_names "$FX_CACHE_DIR")"
case_ran R12

# ── R13 a record from another OS version: the lanes: line carries the advice ─
r_reset
R13_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
R13_NOW="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB")"
R13_OLD="${R13_NOW%%/*}"; R13_OLD="${R13_OLD:-Unknown}/0.0.0-r13"
# Schema 3 at the fixture's 1024 CPUs, so the OS version is the only recalibrate reason.
printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=3\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=1024\nmax_width_measured=1024\nwidth_limit=logical-cpu-count\n' \
    "$R13_HID" "$R13_OLD" > "$FX_CACHE_DIR/parallelism.conf"
R13="$(r_root 1)"
fx_exec "$R13" 60 "$R_OUT" "$R_ERR" -j 2 --all; _rc=$?
assert_eq "R13 run exits 0" "0" "$_rc"
case "$(r_lanes_line)" in
    "jobs 1 of requested "[12]" (max jobs per host 3, source measured; lanes 1"*)
        pass "R13 the measured record sets the limit (max jobs per host 3, source measured)" ;;
    *) fail "R13 lanes: line does not report the measured limit — got $(printf '%q' "$(r_lanes_line)")" ;;
esac
grep -qF -- "; measured on $R13_OLD, now $R13_NOW; re-run RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh" "$R_ERR" \
    && [ -n "$R13_NOW" ] && pass "R13 the lanes: line carries the OS-version advice" \
    || fail "R13 no OS-version advice — now=[$R13_NOW] lanes=$(printf '%q' "$(r_lanes_line)")"
rm -f "$FX_CACHE_DIR/parallelism.conf"
case_ran R13

r_reset
case_end

grp_done run-all-grant-cases.sh
