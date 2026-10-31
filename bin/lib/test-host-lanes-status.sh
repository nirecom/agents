#!/usr/bin/env bash
# The read-only lane listing for bin/test-lanes-status.sh (#2692): line 1 (the lane pool),
# line 2 (the run-all lane allocation sample load/sample), line 3 (the label naming it), the lanes,
# then the presence records with their allocation row.
# Never reclaims, claims or writes. Sourced by test-host-lanes.sh only.

# _thl_status_clean <value> — _THL_SC = <value> with every character outside [A-Za-z0-9._-] as `?`.
_thl_status_clean() {
    _THL_SC="${1//[!A-Za-z0-9._-]/?}"
}

# _thl_status_load — line 2: `load state=none` without a well-formed run-all lane allocation
# sample, else its keys.
_thl_status_load() {
    local k v out="load"
    if ! _thl_sample_read "$THL_CACHE_ROOT/load/sample"; then
        printf 'load state=none\n'
        return 0
    fi
    _thl_sample_fresh 1 >/dev/null 2>&1
    for k in state age_s external_centicores reserved_cores scale_in host_busy_centicores \
        mem_scope mem_avail_mb mem_reserve_mb mem_cap pool; do
        case "$k" in
            state) v="$_THL_S_STATE" ;;
            age_s) v="$_THL_S_AGE" ;;
            external_centicores) v="$_THL_S_EXT" ;;
            reserved_cores) v="$_THL_S_RESERVED" ;;
            scale_in) v="$_THL_S_SCALE" ;;
            host_busy_centicores) v="$_THL_S_HOSTBUSY" ;;
            mem_scope) v="$_THL_S_MEM_SCOPE" ;;
            mem_avail_mb) v="$_THL_S_MEM_AVAIL" ;;
            mem_reserve_mb) v="$_THL_S_MEM_RESERVE" ;;
            mem_cap) v="$_THL_S_MEM_CAP" ;;
            pool) v="$_THL_S_POOL" ;;
        esac
        _thl_status_clean "$v"
        out="$out $k=$_THL_SC"
    done
    printf '%s\n' "$out"
}

# thl_status — the whole listing; `os` on line 1 is shown only after its shape check, and
# line 1 never shows host_id or measured_at.
thl_status() {
    local d i n=0 k=0 runs=0 line rows="" kind env alloc
    thl_max_jobs_per_host
    _thl_sample_read "$THL_CACHE_ROOT/load/sample"
    for d in "$THL_CACHE_ROOT"/runs/run.*; do
        [ -d "$d" ] || continue
        k=$((k + 1))
        _thl_lane_state "$d"
        case "$THL_STATE" in alive|foreign) runs=$((runs + 1)) ;; esac
        if [ "$THL_STATE" = ownerless ]; then
            rows="${rows}run.$k"$'\t-\t-\t-\t-\townerless\t-\t-\t-\t-\n'
            continue
        fi
        alloc=$'-\t-\t-\t-'
        if [ -n "$_THL_O_TOKEN" ] && _thl_sample_row "$_THL_O_TOKEN"; then
            alloc="$_THL_SR_W"$'\t'"$_THL_SR_SS"$'\t'"$_THL_SR_CAP"$'\t'"$_THL_SR_BY"
        fi
        _thl_status_clean "$_THL_O_KIND"; kind="$_THL_SC"
        _thl_status_clean "$_THL_O_ENV"; env="$_THL_SC"
        rows="${rows}run.$k"$'\t'"$kind"$'\t'"$_THL_O_PID"$'\t'"$env"$'\t'"$THL_AGE"$'\t'"$THL_STATE"$'\t'"$alloc"$'\n'
    done
    line="max_jobs_per_host=$THL_MAX_JOBS_PER_HOST source=$THL_MAX_JOBS_PER_HOST_SOURCE"
    [ -n "$THL_RECORD_REASON" ] && line="$line record=$THL_RECORD_REASON"
    [ -n "$THL_RECORD_OS" ] && [ "$THL_RECORD_OS" != "$THL_OS_NOW" ] && line="$line measured_on=$THL_RECORD_OS now=$THL_OS_NOW"
    [ -n "$THL_RECALIBRATE" ] && line="$line recalibrate=$THL_RECALIBRATE"
    case "$THL_CAP_NOTE" in
        capped*) line="$line capped=logical-cpu-count" ;;
        ?*) line="$line logical_cpus=unknown" ;;
    esac
    printf '%s mode=%s runs=%s\n' "$line" "$THL_AUTO_CONFIG" "$runs"
    _thl_status_load
    printf 'load is the run-all lane allocation sample\n'
    for d in "$THL_CACHE_ROOT"/slots/lane.*; do
        [ -d "$d" ] || continue
        i="${d##*/lane.}"
        [[ $i =~ ^[0-9]{1,6}$ ]] || continue
        n=$((n + 1))
        _thl_lane_state "$d"
        if [ "$THL_STATE" = ownerless ]; then
            printf 'lane.%s\t-\t-\t-\t-\townerless\n' "$i"
            continue
        fi
        _thl_status_clean "$_THL_O_KIND"; kind="$_THL_SC"
        _thl_status_clean "$_THL_O_ENV"; env="$_THL_SC"
        printf 'lane.%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$kind" "$_THL_O_PID" "$env" "$THL_AGE" "$THL_STATE"
    done
    [ "$n" -gt 0 ] || printf 'no test lanes held\n'
    printf '%s' "$rows"
    return 0
}
