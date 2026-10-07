#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/never-ask-runner-cases.sh — NA6-NA8 (#2079).
# The never-ask record seen end to end: through the runner's own stderr (the feature-1832
# fixture copy of tests/run-all.sh) and through bin/calibrate-test-parallelism.sh --print,
# which stays exempt from the suppression. Relies on run-all-lease-cases.sh (sourced
# earlier) for the fixture: r_reset, r_root, r_lanes_line, R_OUT, R_ERR, FX_CACHE_DIR.

NR_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
NR_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
NR_NOW="$(bash -c '. "$1"; run_all_os_attr' _ "$PAR_LIB")"
NR_OLD="${NR_NOW%%/*}"; NR_OLD="${NR_OLD:-Unknown}/0.0.0-nr"
NR_HOME="$TMPDIR_BASE/nr-home"; NR_TMP="$TMPDIR_BASE/nr-tmp"
mkdir -p "$NR_HOME" "$NR_TMP"

# nr_never_ask <cache> / nr_os_record <cache> — this host's never-ask record / a measured
# record from another OS version (the shapes the writer and the calibrator emit).
nr_never_ask() {
    printf 'schema=1\nhost_id=%s\nrecorded_at=2026-01-01T00:00:00Z\n' "$NR_HID" > "$1/calibration-never-ask.conf"
}
nr_os_record() {
    printf 'schema=2\nhost_id=%s\nos=%s\nmax_jobs_per_host=3\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\n' \
        "$NR_HID" "$NR_OLD" > "$1/parallelism.conf"
}
nr_clean() { r_reset; rm -f "$FX_CACHE_DIR/calibration-never-ask.conf" "$FX_CACHE_DIR/parallelism.conf"; }
# nr_exec <root> <runner-args...> — the runner with HOME and TMPDIR pinned to the fixture as well.
nr_exec() { local root="$1"; shift; HOME="$NR_HOME" TMPDIR="$NR_TMP" fx_exec "$root" 120 "$R_OUT" "$R_ERR" "$@"; }
# nr_err <label> <present|absent> <fixed-string> [file] — substring presence on stderr.
nr_err() {
    local f="${4:-$R_ERR}" got=absent
    grep -qF -- "$3" "$f" && got=present
    if [[ "$got" == "$2" ]]; then pass "$1"; else fail "$1 — $3 is $got; stderr=$(printf '%q' "$(cat "$f")")"; fi
}
# nr_plan_line <label> <note> — stderr carries exactly the line `[run-all] plan: <note>`.
nr_plan_line() {
    if grep -qxF -- "[run-all] plan: $2" "$R_ERR"; then pass "$1"; else fail "$1 — stderr=$(printf '%q' "$(cat "$R_ERR")")"; fi
}

case_begin "never-ask-runner" "tests/run-all.sh"

if [[ -n "$NR_HID" && -n "$NR_NOW" ]]; then pass "NA precondition: host id and OS attribute resolve"; else fail "NA precondition: host_id=[$NR_HID] os=[$NR_NOW]"; fi
NR_W="$(r_root 8)"
NR_1="$(r_root 1)"

# ── NA6 default source: the runner drops only the calibrator command ────────
nr_clean
nr_exec "$NR_W" --print-plan -j 8 --all; _rc=$?
assert_eq "NA6 control: --print-plan exits 0" "0" "$_rc"
nr_plan_line "NA6 control: without a record the plan line carries the command" \
    "jobs 3 of requested 8 (max jobs per host 4, source default, record missing; calibrate with $NR_HINT; a live lease may grant fewer)"
nr_exec "$NR_1" -j 2 --all; _rc=$?
assert_eq "NA6 control: run exits 0" "0" "$_rc"
nr_err "NA6 control: without a record the lanes: line carries the command" present "record missing; calibrate with $NR_HINT; lanes 1"

nr_clean; nr_never_ask "$FX_CACHE_DIR"
nr_exec "$NR_W" --print-plan -j 8 --all; _rc=$?
assert_eq "NA6 never-ask: --print-plan exits 0" "0" "$_rc"
nr_plan_line "NA6 never-ask: plan line keeps source default / record missing" \
    "jobs 3 of requested 8 (max jobs per host 4, source default, record missing; a live lease may grant fewer)"
nr_err "NA6 never-ask: plan stderr has no calibrator command" absent "$NR_HINT"
nr_err "NA6 never-ask: plan stderr has no 'calibrate with'" absent "calibrate with"
nr_exec "$NR_1" -j 2 --all; _rc=$?
assert_eq "NA6 never-ask: run exits 0" "0" "$_rc"
case "$(r_lanes_line)" in
    "jobs 1 of requested "[12]" (max jobs per host 4, source default, record missing; lanes 1)") pass "NA6 never-ask: lanes: line keeps the facts and drops the command" ;;
    *) fail "NA6 never-ask: lanes: line — got $(printf '%q' "$(r_lanes_line)")" ;;
esac
nr_err "NA6 never-ask: run stderr has no calibrator command" absent "$NR_HINT"
nr_err "NA6 never-ask: run stderr has no 'calibrate with'" absent "calibrate with"
case_ran NA6

# ── NA7 measured record from another OS version: the fact stays, re-run goes ─
nr_clean; nr_os_record "$FX_CACHE_DIR"
nr_exec "$NR_W" --print-plan -j 8 --all; _rc=$?
assert_eq "NA7 control: --print-plan exits 0" "0" "$_rc"
nr_plan_line "NA7 control: without never-ask the plan line carries re-run <command>" \
    "jobs 2 of requested 8 (max jobs per host 3, source measured; a live lease may grant fewer); measured on $NR_OLD, now $NR_NOW; re-run $NR_HINT"

nr_never_ask "$FX_CACHE_DIR"
nr_exec "$NR_W" --print-plan -j 8 --all; _rc=$?
assert_eq "NA7 never-ask: --print-plan exits 0" "0" "$_rc"
nr_plan_line "NA7 never-ask: plan line ends with the OS fact only" \
    "jobs 2 of requested 8 (max jobs per host 3, source measured; a live lease may grant fewer); measured on $NR_OLD, now $NR_NOW"
nr_err "NA7 never-ask: plan stderr has no calibrator command" absent "$NR_HINT"
nr_err "NA7 never-ask: plan stderr has no 're-run'" absent "re-run"
nr_exec "$NR_1" -j 2 --all; _rc=$?
assert_eq "NA7 never-ask: run exits 0" "0" "$_rc"
case "$(r_lanes_line)" in
    "jobs 1 of requested "[12]" (max jobs per host 3, source measured; lanes 1); measured on $NR_OLD, now $NR_NOW") pass "NA7 never-ask: lanes: line ends with the OS fact only" ;;
    *) fail "NA7 never-ask: lanes: line — got $(printf '%q' "$(r_lanes_line)")" ;;
esac
nr_err "NA7 never-ask: run stderr has no calibrator command" absent "$NR_HINT"
nr_err "NA7 never-ask: run stderr has no 're-run'" absent "re-run"
nr_clean
case_ran NA7

case_end

case_begin "never-ask-calibrator-print" "bin/calibrate-test-parallelism.sh"

# ── NA8 calibrate --print is exempt: the full gated command is always shown ──
NA8C="$TMPDIR_BASE/na8-cache"; mkdir -p "$NA8C"
NA8_OUT="$TMPDIR_BASE/na8.out"; NA8_ERR="$TMPDIR_BASE/na8.err"
# na8_print <label> — runs `--print` against NA8C and asserts the record and the advice.
na8_print() {
    local rc=0
    "$RUN_TIMEOUT" 60 env -u RUN_ALL_PARALLELISM_LIB -u TEST_MAX_JOBS_PER_HOST -u RUN_CALIBRATION \
        "HOME=$NR_HOME" "TMPDIR=$NR_TMP" "RUN_ALL_CACHE_DIR=$NA8C" "RUN_ALL_CONFIG_VAR_CMD=$NO_CONFIG_VAR_CMD" \
        bash "$CALIBRATOR" --print >"$NA8_OUT" 2>"$NA8_ERR" || rc=$?
    assert_eq "NA8 $1: --print exits 0" "0" "$rc"
    nr_err "NA8 $1: stdout reports the measured record's os" present "os=$NR_OLD" "$NA8_OUT"
    if grep -qxF -- "calibrate: measured on $NR_OLD, now $NR_NOW; re-run $NR_HINT" "$NA8_ERR"; then
        pass "NA8 $1: stderr carries the full gated command"
    else
        fail "NA8 $1: stderr lacks the advice line — stderr=$(printf '%q' "$(cat "$NA8_ERR")")"
    fi
}
nr_os_record "$NA8C"
na8_print "without never-ask"
nr_never_ask "$NA8C"
na8_print "with a never-ask record"
case_ran NA8

case_end

grp_done never-ask-runner-cases.sh
