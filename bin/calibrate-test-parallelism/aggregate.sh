#!/usr/bin/env bash
# bin/calibrate-test-parallelism/aggregate.sh — median, stability gate, knee, atomic
# publish (SOURCE ONLY). Logic moved unchanged from the pre-#2079 entry point; record v2.

declare -A SAMPLES=()
declare -A MEDIAN=()
SORTED=()
KNEE=""
TMP_FILE=""

sort_samples() {
    local i j key
    SORTED=()
    # shellcheck disable=SC2086
    for key in $1; do SORTED+=("$key"); done
    for ((i = 1; i < ${#SORTED[@]}; i++)); do
        key="${SORTED[$i]}"; j=$((i - 1))
        while [ "$j" -ge 0 ] && [ "${SORTED[$j]}" -gt "$key" ]; do
            SORTED[j + 1]="${SORTED[$j]}"; j=$((j - 1))
        done
        SORTED[j + 1]="$key"
    done
}

# cal_aggregate — the table, then exit 1 when any width's max/min exceeds 1.5; KNEE = the
# smallest width reaching 95% of the best throughput (100*min_median >= 95*median(w)).
cal_aggregate() {
    local w n med lo hi min_median="" unstable=""
    MEDIAN=()
    for w in "${WIDTHS[@]}"; do
        sort_samples "${SAMPLES[$w]:-}"
        n="${#SORTED[@]}"
        [ "$n" -ge 1 ] || die "no measurement was recorded at width $w"
        if [ $((n % 2)) -eq 1 ]; then
            med="${SORTED[$((n / 2))]}"
        else
            med=$(( (SORTED[n / 2 - 1] + SORTED[n / 2]) / 2 ))
        fi
        MEDIAN["$w"]="$med"
        lo="${SORTED[0]}"; hi="${SORTED[$((n - 1))]}"
        if [ "$hi" -gt 0 ] && { [ "$lo" -le 0 ] || [ "$((hi * 10))" -gt "$((lo * 15))" ]; }; then
            unstable="$unstable width $w: min=${lo}ms max=${hi}ms;"
        fi
        if [ -z "$min_median" ] || [ "$med" -lt "$min_median" ]; then min_median="$med"; fi
    done

    printf 'width  median_ms  samples_ms\n'
    for w in "${WIDTHS[@]}"; do
        printf '%-6s %-10s %s\n' "$w" "${MEDIAN[$w]}" "${SAMPLES[$w]}"
    done

    if [ -n "$unstable" ]; then
        printf 'calibrate: measurement unstable (max/min above 1.5x):%s\n' "$unstable" >&2
        printf 'calibrate: no cache written; rerun on an idle machine\n' >&2
        exit 1
    fi
    [ -n "$min_median" ] && [ "$min_median" -gt 0 ] || die "no usable measurement was produced"

    KNEE=""
    for w in "${WIDTHS[@]}"; do
        if [ "$((100 * min_median))" -ge "$((95 * ${MEDIAN[$w]}))" ]; then KNEE="$w"; break; fi
    done
    [ -n "$KNEE" ] || die "no width reached the 95% throughput band"
}

# cal_publish — stage, verify through the reader, then mv (skipped under --no-write, where
# the record is staged in the throwaway work area and never reaches the real area).
cal_publish() {
    local host_id os_attr measured_at cache_dir cache_file
    host_id="$(run_all_host_id)"
    os_attr="$(run_all_os_attr)"
    measured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z')"
    case "$measured_at" in *[!0-9TZ:+-]*) measured_at="1970-01-01T00:00:00Z" ;; esac
    case "$host_id" in *[!A-Za-z0-9._\|-]*) die "host identity failed its own char class" ;; esac
    is_uint "$KNEE" || die "selected width is not an integer: $KNEE"
    cache_dir="$(run_all_cache_dir)"
    cache_file="$(run_all_cache_file)"

    if [ "$NO_WRITE" -eq 1 ]; then
        TMP_FILE="$CAL_WORK/parallelism.conf.staged"
    else
        TMP_FILE="$cache_dir/.parallelism.conf.tmp.$$"
    fi
    {
        printf 'schema=%s\n' "$RUN_ALL_CACHE_SCHEMA"
        printf 'host_id=%s\n' "$host_id"
        printf 'os=%s\n' "$os_attr"
        printf 'max_jobs_per_host=%s\n' "$KNEE"
        printf 'measured_at=%s\n' "$measured_at"
        printf 'sample_size=%s\n' "$SAMPLE_N"
        printf 'repeat=%s\n' "$REPEAT"
    } > "$TMP_FILE" 2>/dev/null || die "could not stage the cache in ${TMP_FILE%/*}"

    # Verify through the reader first, so an unreadable cache is never published even once.
    if ! run_all_cache_read "$TMP_FILE"; then
        die "refusing to publish a cache the reader rejects: $RUN_ALL_CACHE_REASON"
    fi
    if [ "$NO_WRITE" -eq 0 ]; then
        mv -f "$TMP_FILE" "$cache_file" 2>/dev/null || die "could not publish the cache: $cache_file"
    fi
    TMP_FILE=""

    printf 'calibrate: selected max jobs per host %s (sample %s tests; widths %s)\n' "$KNEE" "$SAMPLE_N" "${WIDTHS[*]}"
    if [ "$KNEE" = "$MAX_W" ]; then
        printf 'calibrate: the knee is the widest width measured; the true limit may be higher - rerun with a wider --jobs-list\n'
    fi
    if [ "$NO_WRITE" -eq 1 ]; then
        printf 'calibrate: --no-write: nothing was published to %s\n' "$cache_file"
    else
        printf 'calibrate: wrote %s\n' "$cache_file"
    fi
}
