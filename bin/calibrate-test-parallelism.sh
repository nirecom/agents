#!/usr/bin/env bash
# bin/calibrate-test-parallelism.sh — the ONLY writer of the parallelism cache.
# Explicit-run tool, gated behind RUN_CALIBRATION=1 (see usage below).
# Exit codes: 0 ok | 1 unstable/nothing to print | 2 usage/validation error |
#             5 inconclusive (`calibrate: inconclusive: <token>`) | 77 not requested.
# Entry point only: parse, gate, sequence. Modules: calibrate-test-parallelism/*.sh.

set -u
# The calibrator measures raw width, so its own run-all passes must not be
# narrowed by (or wait on) the host test lanes (#2455).
export TEST_LANES=off

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SELF_DIR/.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
MOD_DIR="$SELF_DIR/calibrate-test-parallelism"
LIB_PATH="${RUN_ALL_PARALLELISM_LIB:-$SELF_DIR/lib/run-all-parallelism.sh}"
DUR_LIB="$SELF_DIR/lib/run-all-durations.sh"
LANES_LIB="$SELF_DIR/lib/test-host-lanes.sh"

die() { printf 'calibrate: %s\n' "$1" >&2; exit "${2:-2}"; }
cal_inconclusive() {
    printf 'calibrate: inconclusive: %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf 'calibrate: %s\n' "$2" >&2
    exit 5
}

for _f in "$LIB_PATH" "$DUR_LIB" "$MOD_DIR/measure.sh" "$MOD_DIR/sample.sh" "$MOD_DIR/probe.sh" "$MOD_DIR/aggregate.sh"; do
    [ -f "$_f" ] || die "calibrator component not found: $_f"
done
# shellcheck source=bin/lib/run-all-parallelism.sh
. "$LIB_PATH"
# shellcheck source=bin/lib/run-all-durations.sh
. "$DUR_LIB"
# shellcheck source=bin/calibrate-test-parallelism/measure.sh
. "$MOD_DIR/measure.sh"
# shellcheck source=bin/calibrate-test-parallelism/sample.sh
. "$MOD_DIR/sample.sh"
# shellcheck source=bin/calibrate-test-parallelism/probe.sh
. "$MOD_DIR/probe.sh"
# shellcheck source=bin/calibrate-test-parallelism/aggregate.sh
. "$MOD_DIR/aggregate.sh"

SAMPLE=""
JOBS_LIST="4 6 8 12 16"
REPEAT=3
WARMUP=1
BAND="5:10"
TIME_LIMIT=90
NO_WRITE=0
MODE="measure"
MAX_REVISIONS=3

usage() {
    cat <<'USAGE'
Usage: bin/calibrate-test-parallelism.sh [options]

Measures a ledger-chosen test sample at several parallel widths and records the
knee in the host-local parallelism cache. Requires RUN_CALIBRATION=1 to measure.

  --sample N        tests per measurement (default 3 x the widest width)
  --jobs-list "..." widths to measure (default "4 6 8 12 16")
  --repeat N        measured passes per width (default 3)
  --warmup N        discarded passes per width (default 1)
  --band LO:HI      seconds a test must take to be sampled (default 5:10)
  --time-limit MIN  stop as inconclusive before exceeding this (default 90)
  --no-write        measure and select, but publish nothing
  --dry-run         show the plan and cost, measure nothing
  --print           show the cached decision, measure nothing
  -h, --help        this text

Exit 5 = inconclusive: plan-unavailable, too-few-candidates, infeasible-sample,
lanes-busy, width-not-honoured, run-failed, reserve-exhausted,
revisions-exhausted, time-limit. Nothing is written in that case.
Env: RUN_ALL_CACHE_DIR, TESTS_DIR, RUN_CALIBRATION,
     RUN_ALL_CALIBRATION_MEASURE_CMD (test seam: <width> <list> <deadline> <phase>).
USAGE
}

need_value() { [ "$1" -ge 2 ] || die "option $2 requires a value"; }

# --- 1. parse ---------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) MODE="dry-run"; shift ;;
        --print)   MODE="print"; shift ;;
        --no-write) NO_WRITE=1; shift ;;
        --sample)      need_value "$#" "$1"; SAMPLE="$2"; shift 2 ;;
        --sample=*)    SAMPLE="${1#*=}"; shift ;;
        --jobs-list)   need_value "$#" "$1"; JOBS_LIST="$2"; shift 2 ;;
        --jobs-list=*) JOBS_LIST="${1#*=}"; shift ;;
        --repeat)      need_value "$#" "$1"; REPEAT="$2"; shift 2 ;;
        --repeat=*)    REPEAT="${1#*=}"; shift ;;
        --warmup)      need_value "$#" "$1"; WARMUP="$2"; shift 2 ;;
        --warmup=*)    WARMUP="${1#*=}"; shift ;;
        --band)        need_value "$#" "$1"; BAND="$2"; shift 2 ;;
        --band=*)      BAND="${1#*=}"; shift ;;
        --time-limit)  need_value "$#" "$1"; TIME_LIMIT="$2"; shift 2 ;;
        --time-limit=*) TIME_LIMIT="${1#*=}"; shift ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
    esac
done
[ "$#" -eq 0 ] || die "unexpected positional argument: $1"

# --- 2. validate argument VALUES --------------------------------------------
# Every value is checked against a digit class before arithmetic — rejects
# injection via $(...), backticks, ;, && before anything is written or measured.
is_uint "$REPEAT" || die "--repeat must be a positive integer, got: $REPEAT"
[ "$REPEAT" -ge 1 ] || die "--repeat must be >= 1, got: $REPEAT"
is_uint "$WARMUP" || die "--warmup must be a non-negative integer, got: $WARMUP"
is_uint "$TIME_LIMIT" || die "--time-limit must be a positive integer of minutes, got: $TIME_LIMIT"
[ "$TIME_LIMIT" -ge 1 ] || die "--time-limit must be >= 1, got: $TIME_LIMIT"
BAND_LO="${BAND%%:*}"; BAND_HI="${BAND#*:}"
{ is_uint "$BAND_LO" && is_uint "$BAND_HI"; } || die "--band must be LO:HI in whole seconds, got: $BAND"
[ "$BAND_LO" -ge 1 ] && [ "$BAND_LO" -le "$BAND_HI" ] && [ "$BAND_HI" -le 9999 ] ||
    die "--band needs 1 <= LO <= HI <= 9999, got: $BAND"

case "$JOBS_LIST" in
    *[!0-9\ ]*) die "--jobs-list accepts space-separated positive integers only" ;;
esac
WIDTHS=()
set -f
# shellcheck disable=SC2086
for _w in $JOBS_LIST; do
    is_uint "$_w" || die "--jobs-list token is not an integer: $_w"
    [ "$_w" -ge "$RUN_ALL_CACHE_MIN_JOBS" ] && [ "$_w" -le "$RUN_ALL_CACHE_MAX_JOBS" ] ||
        die "--jobs-list width out of range 1..$RUN_ALL_CACHE_MAX_JOBS: $_w"
    WIDTHS+=("$_w")
done
set +f
[ "${#WIDTHS[@]}" -ge 1 ] || die "--jobs-list must name at least one width"
# Ascending and de-duplicated: the knee rule adopts the SMALLEST width in the band.
mapfile -t WIDTHS < <(printf '%s\n' "${WIDTHS[@]}" | sort -n -u)
MIN_W="${WIDTHS[0]}"; MAX_W="${WIDTHS[$((${#WIDTHS[@]} - 1))]}"

if [ -z "$SAMPLE" ]; then
    SAMPLE_N=$((3 * MAX_W))
else
    is_uint "$SAMPLE" || die "--sample must be a positive integer, got: $SAMPLE"
    [ "$SAMPLE" -ge "$MAX_W" ] || die "--sample must be >= the widest width ($MAX_W), got: $SAMPLE"
    SAMPLE_N="$SAMPLE"
fi
REQUIRED=$((SAMPLE_N + (SAMPLE_N + 3) / 4))

# --- 3. inquiry: --print needs no plan ----------------------------------------
CACHE_DIR="$(run_all_cache_dir)"
CACHE_FILE="$(run_all_cache_file)"
if [ "$MODE" = "print" ]; then
    if run_all_cache_read "$CACHE_FILE"; then
        printf 'max_jobs_per_host=%s\n' "$RUN_ALL_CACHE_MAX_JOBS_PER_HOST"
        printf 'os=%s\n' "$RUN_ALL_CACHE_OS"
        printf 'measured_at=%s\n' "$RUN_ALL_CACHE_MEASURED_AT"
        OS_NOW="$(run_all_os_attr)"
        if [ "$RUN_ALL_CACHE_OS" != "$OS_NOW" ]; then
            printf 'calibrate: measured on %s, now %s; re-run %s\n' "$RUN_ALL_CACHE_OS" "$OS_NOW" "$RUN_ALL_CALIBRATOR_HINT" >&2
        fi
        exit 0
    fi
    printf 'calibrate: no usable cache (%s): %s\n' "$RUN_ALL_CACHE_REASON" "$CACHE_FILE" >&2
    exit 1
fi

# The work area holds plan/list/report files and every child's throwaway cache area.
CAL_WORK="$(mktemp -d 2>/dev/null)" || die "cannot create a temporary work directory"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cal_cleanup() {
    [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"
    [ -n "${CAL_WORK:-}" ] && rm -rf "$CAL_WORK"
    return 0
}
trap cal_cleanup EXIT
CAL_T0=$SECONDS
TESTS_DIR="${TESTS_DIR:-$AGENTS_DIR/tests}"
export TESTS_DIR
MEASURE_CMD="${RUN_ALL_CALIBRATION_MEASURE_CMD:-}"

# --- 4. population and ledger candidates (read only) -------------------------
cal_population || cal_inconclusive plan-unavailable "the runner could not list the tests under $TESTS_DIR"
cal_ledger_secs

if [ "$MODE" = "dry-run" ]; then
    cal_dry_run
    exit 0
fi

# --- 5. the explicit-run gate ------------------------------------------------
case "${RUN_CALIBRATION:-}" in
    1) ;;
    *)
        printf 'calibrate: refusing to measure without RUN_CALIBRATION=1\n' >&2
        printf 'calibrate: try --dry-run to see the cost, or --print for the cached decision\n' >&2
        exit 77 ;;
esac

# --- 6. the destination must be usable BEFORE anything is measured -----------
if [ "$NO_WRITE" -eq 0 ]; then
    mkdir -p "$CACHE_DIR" 2>/dev/null || die "cache destination is not writable: $CACHE_DIR"
    [ -d "$CACHE_DIR" ] && [ -w "$CACHE_DIR" ] || die "cache destination is not writable: $CACHE_DIR"
fi

# --- 7. no live lane holder in the real area (before the first child run) -----
if [ -f "$LANES_LIB" ]; then
    # shellcheck source=bin/lib/test-host-lanes.sh
    . "$LANES_LIB"
    for _d in "$CACHE_DIR"/slots/lane.*; do
        [ -d "$_d" ] || continue
        _thl_lane_state "$_d"
        case "$THL_STATE" in
            alive|foreign) cal_inconclusive lanes-busy "another test run holds ${_d##*/}; rerun on an idle host" ;;
        esac
    done
fi

# --- 8. probe, sample, feasibility ------------------------------------------
cal_probe
if [ "${#CAND_PATH[@]}" -lt "$SAMPLE_N" ]; then
    printf 'calibrate: inconclusive: too-few-candidates\n' >&2
    printf 'calibrate: need %s candidates (%s with reserve); ledger gave %s, probing %s tests gave %s more\n' \
        "$SAMPLE_N" "$REQUIRED" "$LEDGER_CANDS" "$PROBED" "$(( ${#CAND_PATH[@]} - LEDGER_CANDS ))" >&2
    printf 'calibrate: widen --band (now %s) or narrow --jobs-list (now %s)\n' "$BAND" "${WIDTHS[*]}" >&2
    exit 5
fi
cal_select
cal_feasible

# --- 9. warmup and measurement, restarted on every sample revision -----------
SAMPLE_LIST="$CAL_WORK/sample.list"
REPORT="$CAL_WORK/run.report"
REVISIONS=0

# cal_call <phase> <width> — one checked run of the current sample; 1 on an overrun.
cal_call() {
    cal_time_check "$CAL_D"
    cal_measure_call "$2" "$SAMPLE_LIST" "$CAL_D" "$1" "$REPORT" ||
        cal_inconclusive run-failed "could not start the $1 run at width $2"
    cal_check_report "$1" "$2" "$REPORT" "$SAMPLE_LIST"
    [ "${#CAL_OVERRUN[@]}" -eq 0 ] || return 1
    [ "$1" = "measure" ] && SAMPLES["$2"]="${SAMPLES[$2]:-}$CAL_MS "
    return 0
}

# cal_ladder — warmup passes ascending, then repeats crossing order (odd up, even down) so
# monotonic drift cancels instead of accruing to one end. 1 on the first overrun.
cal_ladder() {
    local k r i
    SAMPLES=()
    printf '%s\n' "${SAMPLE_P[@]}" > "$SAMPLE_LIST"
    cal_predict "$MIN_W" "$SAMPLE_SUM" "$SAMPLE_LONGEST"
    CAL_D=$((2 * CAL_P + 30))
    cal_estimate "$SAMPLE_SUM" "$SAMPLE_LONGEST"
    printf 'calibrate: sample %s tests, reserve %s; ~%ss per pass, ~%ss total; deadline %ss per run\n' \
        "${#SAMPLE_P[@]}" "${#RESERVE_P[@]}" "$CAL_PASS_S" "$CAL_TOTAL_S" "$CAL_D" >&2
    for ((k = 0; k < WARMUP; k++)); do
        for i in "${WIDTHS[@]}"; do cal_call warmup "$i" || return 1; done
    done
    for ((r = 1; r <= REPEAT; r++)); do
        if [ $((r % 2)) -eq 1 ]; then
            for ((i = 0; i < ${#WIDTHS[@]}; i++)); do cal_call measure "${WIDTHS[$i]}" || return 1; done
        else
            for ((i = ${#WIDTHS[@]} - 1; i >= 0; i--)); do cal_call measure "${WIDTHS[$i]}" || return 1; done
        fi
    done
    return 0
}

until cal_ladder; do
    [ "$REVISIONS" -lt "$MAX_REVISIONS" ] ||
        cal_inconclusive revisions-exhausted "$MAX_REVISIONS sample revisions did not stop the overruns"
    cal_replace_overrun
    REVISIONS=$((REVISIONS + 1))
    printf 'calibrate: revision %s: replaced %s overrunning test(s); restarting from warmup\n' \
        "$REVISIONS" "${#CAL_OVERRUN[@]}" >&2
done

# --- 10. aggregate, select, publish ------------------------------------------
cal_aggregate
cal_publish
exit 0
