#!/usr/bin/env bash
# bin/calibrate-test-parallelism.sh — the ONLY writer of the parallelism cache.
#
# Explicit-run tool: no path in tests/run-all.sh reaches it. A real measurement
# drives the suite many times, so it is gated behind RUN_CALIBRATION=1 while the
# inquiry sub-modes (--help / --dry-run / --print) cost nothing. The suite's own
# stdout is never re-emitted — it carries the RUN_CONTRACT line the PostToolUse
# hook attributes, and a second copy would corrupt that attribution.
#
# Exit codes: 0 ok | 1 measurement unstable, or nothing to print | 2 usage,
# validation or measurement failure | 77 not explicitly requested.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SELF_DIR/.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
LIB_PATH="${RUN_ALL_PARALLELISM_LIB:-$SELF_DIR/lib/run-all-parallelism.sh}"

if [ ! -f "$LIB_PATH" ]; then
    printf 'calibrate: parallelism library not found: %s\n' "$LIB_PATH" >&2
    exit 2
fi
# shellcheck source=bin/lib/run-all-parallelism.sh
. "$LIB_PATH"

SAMPLE=24
JOBS_LIST="1 2 4 8 12 16"
REPEAT=3
WARMUP=1
MODE="measure"

die() { printf 'calibrate: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
    cat <<'USAGE'
Usage: bin/calibrate-test-parallelism.sh [options]

Measures the test suite at several parallel widths and records the knee in the
host-local parallelism cache. Requires RUN_CALIBRATION=1 to measure.

  --sample N        representative tests per measurement (default 24)
  --jobs-list "..." widths to measure (default "1 2 4 8 12 16")
  --repeat N        measured passes per width (default 3)
  --warmup N        discarded passes per width (default 1)
  --dry-run         show the plan and cost, measure nothing
  --print           show the cached decision, measure nothing
  -h, --help        this text

Env: RUN_ALL_CACHE_DIR, TESTS_DIR, RUN_CALIBRATION,
     RUN_ALL_CALIBRATION_MEASURE_CMD (test seam; replaces the timed suite run).
USAGE
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 9 ]
}

need_value() { [ "$1" -ge 2 ] || die "option $2 requires a value"; }

# --- 1. parse ---------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dry-run) MODE="dry-run"; shift ;;
        --print)   MODE="print"; shift ;;
        --sample)    need_value "$#" "$1"; SAMPLE="$2"; shift 2 ;;
        --sample=*)  SAMPLE="${1#*=}"; shift ;;
        --jobs-list)   need_value "$#" "$1"; JOBS_LIST="$2"; shift 2 ;;
        --jobs-list=*) JOBS_LIST="${1#*=}"; shift ;;
        --repeat)    need_value "$#" "$1"; REPEAT="$2"; shift 2 ;;
        --repeat=*)  REPEAT="${1#*=}"; shift ;;
        --warmup)    need_value "$#" "$1"; WARMUP="$2"; shift 2 ;;
        --warmup=*)  WARMUP="${1#*=}"; shift ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
    esac
done
[ "$#" -eq 0 ] || die "unexpected positional argument: $1"

# --- 2. validate argument VALUES --------------------------------------------
#
# Every value is matched as text against a digit class before any arithmetic, so
# `$(...)`, backticks, `;`, `&&` and embedded newlines are rejected as data and
# never reach a shell. Nothing has been written or measured at this point.

is_uint "$SAMPLE" || die "--sample must be a positive integer, got: $SAMPLE"
[ "$SAMPLE" -ge 1 ] || die "--sample must be >= 1, got: $SAMPLE"
is_uint "$REPEAT" || die "--repeat must be a positive integer, got: $REPEAT"
[ "$REPEAT" -ge 1 ] || die "--repeat must be >= 1, got: $REPEAT"
is_uint "$WARMUP" || die "--warmup must be a non-negative integer, got: $WARMUP"

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

# Ascending order is load-bearing: the knee rule adopts the SMALLEST width that
# reaches the throughput band, so the scan must see widths in increasing order.
sort_widths() {
    local i j key
    for ((i = 1; i < ${#WIDTHS[@]}; i++)); do
        key="${WIDTHS[$i]}"; j=$((i - 1))
        while [ "$j" -ge 0 ] && [ "${WIDTHS[$j]}" -gt "$key" ]; do
            WIDTHS[$((j + 1))]="${WIDTHS[$j]}"; j=$((j - 1))
        done
        WIDTHS[$((j + 1))]="$key"
    done
}
sort_widths
DEDUPED=()
_prev=""
for _w in "${WIDTHS[@]}"; do
    [ "$_w" = "$_prev" ] && continue
    DEDUPED+=("$_w"); _prev="$_w"
done
WIDTHS=("${DEDUPED[@]}")

# --- 3. representative subset ------------------------------------------------

TESTS_DIR="${TESTS_DIR:-$AGENTS_DIR/tests}"
[ -d "$TESTS_DIR" ] || die "test directory not found: $TESTS_DIR"

CANDIDATES=()
for _f in "$TESTS_DIR"/*.sh; do
    [ -f "$_f" ] || continue
    # `# Serial:` tests are excluded: they cannot overlap, so they measure the
    # same wall time at every width and only flatten the curve.
    if head -n 20 "$_f" 2>/dev/null | grep -q '^# Serial:'; then continue; fi
    CANDIDATES+=("$_f")
done
CORPUS_COUNT="$(run_all_corpus_count "$TESTS_DIR")"
[ "${#CANDIDATES[@]}" -ge 1 ] || die "no parallelisable tests found in: $TESTS_DIR"

TAKE="$SAMPLE"
[ "$TAKE" -le "${#CANDIDATES[@]}" ] || TAKE="${#CANDIDATES[@]}"
SAMPLE_FILES=()
_i=0
while [ "$_i" -lt "$TAKE" ]; do
    SAMPLE_FILES+=("${CANDIDATES[$((_i * ${#CANDIDATES[@]} / TAKE))]}")
    _i=$((_i + 1))
done

CACHE_DIR="$(run_all_cache_dir)"
CACHE_FILE="$(run_all_cache_file)"

# --- 4. inquiry sub-modes ----------------------------------------------------

if [ "$MODE" = "dry-run" ]; then
    _runs=$(( (${#WIDTHS[@]}) * (REPEAT + WARMUP) ))
    printf 'plan: widths=%s repeat=%s warmup=%s sample=%s\n' \
        "${WIDTHS[*]}" "$REPEAT" "$WARMUP" "$TAKE"
    printf 'plan: %s suite runs, %s test executions\n' "$_runs" "$((_runs * TAKE))"
    printf 'plan: cache destination %s\n' "$CACHE_FILE"
    printf 'plan: nothing was measured and nothing was written\n'
    exit 0
fi

if [ "$MODE" = "print" ]; then
    if run_all_cache_read "$CACHE_FILE"; then
        printf 'jobs=%s\n' "$RUN_ALL_CACHE_JOBS"
        printf 'measured_at=%s\n' "$RUN_ALL_CACHE_MEASURED_AT"
        exit 0
    fi
    printf 'calibrate: no usable cache (%s): %s\n' "$RUN_ALL_CACHE_REASON" "$CACHE_FILE" >&2
    exit 1
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

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    die "cache destination is not writable: $CACHE_DIR"
fi
if [ ! -d "$CACHE_DIR" ] || [ ! -w "$CACHE_DIR" ]; then
    die "cache destination is not writable: $CACHE_DIR"
fi

# --- 7. measurement ----------------------------------------------------------

now_ms() {
    local t s f
    t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        s="${t%%[.,]*}"; f="${t#*[.,]}"
        f="${f}000"; f="${f:0:3}"
        printf '%s' "$((s * 1000 + 10#$f))"
        return 0
    fi
    t="$(date +%s 2>/dev/null)"
    is_uint "$t" || t=0
    printf '%s' "$((t * 1000))"
}

MEASURE_CMD="${RUN_ALL_CALIBRATION_MEASURE_CMD:-}"

# The seam is TOTAL: when set, every measurement — warmups included — routes
# through it, so a sentinel installed there sees any calibration that starts.
measure_seam() {
    local out line
    out="$(bash "$MEASURE_CMD" "$1" 2>/dev/null)" || return 1
    line="${out%%$'\n'*}"
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    is_uint "$line" || return 1
    printf '%s' "$line"
}

measure_real() {
    local t0 t1 rc=0
    t0="$(now_ms)"
    bash "$RUNNER" -j "$1" "${SAMPLE_FILES[@]}" >/dev/null 2>&1 || rc=$?
    t1="$(now_ms)"
    # rc 1 only means some test failed; the timing is still a valid sample.
    [ "$rc" -le 1 ] || return 1
    printf '%s' "$((t1 - t0))"
}

measure_once() {
    if [ -n "$MEASURE_CMD" ]; then measure_seam "$1"; else measure_real "$1"; fi
}

declare -A SAMPLES=()

record() {
    local w="$1" ms
    ms="$(measure_once "$w")" || die "measurement failed at width $w"
    SAMPLES["$w"]="${SAMPLES[$w]:-}$ms "
}

# Warmup first, per width: the discarded pass pays the filesystem and
# anti-virus warm-up for that width so it lands outside every measured pass.
_k=0
while [ "$_k" -lt "$WARMUP" ]; do
    for _w in "${WIDTHS[@]}"; do
        measure_once "$_w" >/dev/null || die "warmup failed at width $_w"
    done
    _k=$((_k + 1))
done

# Order-crossing traversal: odd repeats ascend, even repeats descend, so any
# monotonic drift over the run cancels instead of accruing to one end.
_r=1
while [ "$_r" -le "$REPEAT" ]; do
    if [ $((_r % 2)) -eq 1 ]; then
        for _w in "${WIDTHS[@]}"; do record "$_w"; done
    else
        _i=$((${#WIDTHS[@]} - 1))
        while [ "$_i" -ge 0 ]; do record "${WIDTHS[$_i]}"; _i=$((_i - 1)); done
    fi
    _r=$((_r + 1))
done

# --- 8. aggregate, gate, select ---------------------------------------------

SORTED=()
sort_samples() {
    local i j key
    SORTED=()
    # shellcheck disable=SC2086
    for key in $1; do SORTED+=("$key"); done
    for ((i = 1; i < ${#SORTED[@]}; i++)); do
        key="${SORTED[$i]}"; j=$((i - 1))
        while [ "$j" -ge 0 ] && [ "${SORTED[$j]}" -gt "$key" ]; do
            SORTED[$((j + 1))]="${SORTED[$j]}"; j=$((j - 1))
        done
        SORTED[$((j + 1))]="$key"
    done
}

declare -A MEDIAN=()
MIN_MEDIAN=""
UNSTABLE=""

for _w in "${WIDTHS[@]}"; do
    sort_samples "${SAMPLES[$_w]}"
    _n="${#SORTED[@]}"
    if [ $((_n % 2)) -eq 1 ]; then
        _med="${SORTED[$((_n / 2))]}"
    else
        _med=$(( (SORTED[_n / 2 - 1] + SORTED[_n / 2]) / 2 ))
    fi
    MEDIAN["$_w"]="$_med"
    _lo="${SORTED[0]}"; _hi="${SORTED[$((_n - 1))]}"
    # max/min > 1.5 in integers, so no floating point enters the gate.
    if [ "$_hi" -gt 0 ] && { [ "$_lo" -le 0 ] || [ "$((_hi * 10))" -gt "$((_lo * 15))" ]; }; then
        UNSTABLE="$UNSTABLE width $_w: min=${_lo}ms max=${_hi}ms;"
    fi
    if [ -z "$MIN_MEDIAN" ] || [ "$_med" -lt "$MIN_MEDIAN" ]; then MIN_MEDIAN="$_med"; fi
done

printf 'width  median_ms  samples_ms\n'
for _w in "${WIDTHS[@]}"; do
    printf '%-6s %-10s %s\n' "$_w" "${MEDIAN[$_w]}" "${SAMPLES[$_w]}"
done

if [ -n "$UNSTABLE" ]; then
    printf 'calibrate: measurement unstable (max/min above 1.5x):%s\n' "$UNSTABLE" >&2
    printf 'calibrate: no cache written; rerun on an idle machine\n' >&2
    exit 1
fi
[ -n "$MIN_MEDIAN" ] && [ "$MIN_MEDIAN" -gt 0 ] || die "no usable measurement was produced"

# Knee: the smallest width reaching 95% of the best observed throughput. With
# throughput = 1/elapsed that is 100*min_median >= 95*median(w), kept integral.
KNEE=""
for _w in "${WIDTHS[@]}"; do
    if [ "$((100 * MIN_MEDIAN))" -ge "$((95 * ${MEDIAN[$_w]}))" ]; then KNEE="$_w"; break; fi
done
[ -n "$KNEE" ] || die "no width reached the 95% throughput band"

# --- 9. atomic write ---------------------------------------------------------

BUCKET="$(run_all_count_bucket "$CORPUS_COUNT")"
HOST_ID="$(run_all_host_id)"
MEASURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z')"

case "$MEASURED_AT" in *[!0-9TZ:+-]*) MEASURED_AT="1970-01-01T00:00:00Z" ;; esac
case "$HOST_ID" in *[!A-Za-z0-9._\|-]*) die "host identity failed its own char class" ;; esac
is_uint "$BUCKET" || die "corpus bucket is not an integer: $BUCKET"
is_uint "$KNEE" || die "selected width is not an integer: $KNEE"

TMP_FILE="$CACHE_DIR/.parallelism.conf.tmp.$$"
trap 'rm -f "$TMP_FILE"' EXIT
{
    printf 'schema=%s\n' "$RUN_ALL_CACHE_SCHEMA"
    printf 'host_id=%s\n' "$HOST_ID"
    printf 'count_bucket=%s\n' "$BUCKET"
    printf 'jobs=%s\n' "$KNEE"
    printf 'measured_at=%s\n' "$MEASURED_AT"
    printf 'sample_size=%s\n' "$TAKE"
    printf 'repeat=%s\n' "$REPEAT"
} > "$TMP_FILE" 2>/dev/null || die "could not stage the cache in $CACHE_DIR"

# Verify the staged file through the reader before it becomes the live cache, so
# an unreadable cache can never be published even once.
if ! run_all_cache_read "$TMP_FILE" "$BUCKET"; then
    die "refusing to publish a cache the reader rejects: $RUN_ALL_CACHE_REASON"
fi
mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null || die "could not publish the cache: $CACHE_FILE"
trap - EXIT

printf 'calibrate: selected -j %s (corpus %s tests, bucket %s)\n' "$KNEE" "$CORPUS_COUNT" "$BUCKET"
printf 'calibrate: wrote %s\n' "$CACHE_FILE"
exit 0
