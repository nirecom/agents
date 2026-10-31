#!/usr/bin/env bash
# Run-all per-run lane cap over the run-all lane pool (#2687, #2692): every run-all keeps a
# presence record runs/run.<token>; the load claim holder writes each run's row
# (test-host-alloc.sh) and every run-all follows its own row at each entry-script end. A run
# starts at up to 4 lanes inside its per-run lane cap and the headroom (slow start). Sourced by
# test-host-lanes.sh only.
# shellcheck disable=SC2034,SC2153  # globals shared with test-host-lanes.sh and its callers

THL_PER_RUN_CAP=0
THL_WIDTH=0
THL_LANES_DEGRADED=0
THL_PRESENCE_START=""
THL_PRC_ALLOC=()
_THL_OWN_DEMAND=1
_THL_LEASE_TOP=1
_THL_LEASE_WANT=1
_THL_SHARE_POOL=1
_THL_SHARE_RUNS=1
_THL_SHARE_SCALE=0
_THL_START_W=0
_THL_REB_ROW=0
_THL_REB_AT=""
_THL_PS_ST=()
_THL_PS_TK=()
_THL_PS_DM=()
_THL_PS_BASE=1

# _thl_per_run_cap_all <pool> <demand...> — THL_PRC_ALLOC, every run's per-run lane cap in
# start order: water-fill, the remainder going to the earliest runs; with more runs than the
# pool, the first <pool> runs get 1.
_thl_per_run_cap_all() {
    local pool="$1" n i q rem active give
    shift
    local -a dem=("$@")
    n=${#dem[@]}
    THL_PRC_ALLOC=()
    for ((i = 0; i < n; i++)); do
        THL_PRC_ALLOC[i]=0
        [[ ${dem[i]} =~ ^[1-9][0-9]*$ ]] || dem[i]=1
    done
    if [ "$n" -gt "$pool" ]; then
        for ((i = 0; i < pool; i++)); do THL_PRC_ALLOC[i]=1; done
        return 0
    fi
    rem="$pool"
    while [ "$rem" -gt 0 ]; do
        active=0
        for ((i = 0; i < n; i++)); do [ "${THL_PRC_ALLOC[i]}" -lt "${dem[i]}" ] && active=$((active + 1)); done
        [ "$active" -gt 0 ] || break
        q=$((rem / active))
        for ((i = 0; i < n && rem > 0; i++)); do
            [ "${THL_PRC_ALLOC[i]}" -lt "${dem[i]}" ] || continue
            give="$q"
            [ "$give" -gt 0 ] || give=1
            [ "$give" -gt $((dem[i] - THL_PRC_ALLOC[i])) ] && give=$((dem[i] - THL_PRC_ALLOC[i]))
            THL_PRC_ALLOC[i]=$((THL_PRC_ALLOC[i] + give))
            rem=$((rem - give))
        done
    done
    return 0
}

# thl_presence_enter <max-jobs-per-run> — create (or re-create) runs/run.<THL_TOKEN>.
thl_presence_enter() {
    local r="$THL_CACHE_ROOT/runs" d
    _THL_OWN_DEMAND="$1"
    [ -n "$THL_PRESENCE_START" ] || { _thl_now; THL_PRESENCE_START="$THL_NOW"; }
    d="$r/run.$THL_TOKEN"
    [ -d "$r" ] || mkdir -p "$r" 2>/dev/null
    mkdir "$d" 2>/dev/null || [ -d "$d" ] || return 1
    _thl_now
    { printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\nmax_jobs_per_run=%s\nmax_jobs_per_host=%s\n' \
        "$$" "${OSTYPE:-}" "$THL_PRESENCE_START" "$THL_TOKEN" "$1" "$THL_MAX_JOBS_PER_HOST" > "$d/owner"; } 2>/dev/null
    { printf '%s\n' "$THL_NOW" > "$d/hb"; } 2>/dev/null
    return 0
}

# _thl_presence_scan — the live presence records in start order (_THL_PS_ST/TK/DM) and
# _THL_PS_BASE (their smallest max jobs per host); stale records are reclaimed.
_thl_presence_scan() {
    local r="$THL_CACHE_ROOT/runs" d tok base="" i j n ts tt td
    _THL_PS_ST=(); _THL_PS_TK=(); _THL_PS_DM=()
    if [ -n "$THL_TOKEN" ] && [ ! -d "$r/run.$THL_TOKEN" ]; then thl_presence_enter "$_THL_OWN_DEMAND"; fi
    for d in "$r"/run.*; do
        [ -d "$d" ] || continue
        tok="${d##*/run.}"
        _thl_lane_state "$d"
        case "$THL_STATE" in
            alive|foreign) ;;
            stale-*) _thl_reclaim_one "$d" "$_THL_O_TOKEN"; continue ;;
            *) continue ;;
        esac
        [ -n "$_THL_O_START" ] || continue
        _THL_PS_ST+=("$((10#$_THL_O_START))"); _THL_PS_TK+=("${_THL_O_TOKEN:-$tok}"); _THL_PS_DM+=("${_THL_O_MJPR:-1000}")
        if [ -n "$_THL_O_MJPH" ] && { [ -z "$base" ] || [ "$_THL_O_MJPH" -lt "$base" ]; }; then base="$_THL_O_MJPH"; fi
    done
    n=${#_THL_PS_ST[@]}
    for ((i = 1; i < n; i++)); do
        ts="${_THL_PS_ST[i]}"; tt="${_THL_PS_TK[i]}"; td="${_THL_PS_DM[i]}"
        for ((j = i - 1; j >= 0; j--)); do
            if [ "${_THL_PS_ST[j]}" -gt "$ts" ] || { [ "${_THL_PS_ST[j]}" -eq "$ts" ] && [[ ${_THL_PS_TK[j]} > $tt ]]; }; then
                _THL_PS_ST[j + 1]="${_THL_PS_ST[j]}"; _THL_PS_TK[j + 1]="${_THL_PS_TK[j]}"; _THL_PS_DM[j + 1]="${_THL_PS_DM[j]}"
            else
                break
            fi
        done
        _THL_PS_ST[j + 1]="$ts"; _THL_PS_TK[j + 1]="$tt"; _THL_PS_DM[j + 1]="$td"
    done
    if [ -z "$base" ]; then
        [ -n "$THL_MAX_JOBS_PER_HOST" ] || thl_max_jobs_per_host
        base="$THL_MAX_JOBS_PER_HOST"
    fi
    _THL_PS_BASE="$base"
    return 0
}

# _thl_start_width — _THL_START_W = min(4, the lease's want, per-run lane cap, headroom), at
# least 0. Pool = the fresh sample's pool (else max(1, base - 1)); per-run lane cap = this run's
# max-min share of it over every live presence record's demand; headroom = pool minus the lanes
# other live run-alls hold. With an own row in the fresh sample: min(its width, the lease's
# want) instead. Also sets _THL_SHARE_RUNS/POOL.
_thl_start_width() {
    local pool t h=0 i prc own=0
    _thl_presence_scan
    _THL_SHARE_RUNS=${#_THL_PS_TK[@]}
    pool=1; [ "$_THL_PS_BASE" -ge 2 ] && pool=$((_THL_PS_BASE - 1))
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    if _thl_sample_read "$THL_CACHE_ROOT/load/sample" && _thl_sample_fresh "$_THL_INT"; then
        pool="$_THL_S_POOL"
        _thl_sample_row "$THL_TOKEN" && own=1
    fi
    _THL_SHARE_POOL="$pool"; prc="$pool"
    if [ "$own" = 1 ]; then
        _THL_START_W="$_THL_SR_W"
        [ "$_THL_START_W" -le "$_THL_LEASE_WANT" ] || _THL_START_W="$_THL_LEASE_WANT"
        [ "$_THL_START_W" -ge 0 ] || _THL_START_W=0
        return 0
    fi
    _thl_per_run_cap_all "$pool" ${_THL_PS_DM[@]+"${_THL_PS_DM[@]}"}
    for ((i = 0; i < _THL_SHARE_RUNS; i++)); do
        [ "${_THL_PS_TK[i]}" = "$THL_TOKEN" ] && { prc="${THL_PRC_ALLOC[i]:-0}"; break; }
    done
    _thl_alloc_held "$_THL_LEASE_TOP"
    for t in $_THL_AH_TOKS; do [ "$t" = "$THL_TOKEN" ] || h=$((h + 1)); done
    _THL_START_W="$THL_SLOW_START_INIT"
    [ "$_THL_START_W" -le "$_THL_LEASE_WANT" ] || _THL_START_W="$_THL_LEASE_WANT"
    [ "$_THL_START_W" -le "$prc" ] || _THL_START_W="$prc"
    [ "$_THL_START_W" -le $((pool - h)) ] || _THL_START_W=$((pool - h))
    [ "$_THL_START_W" -ge 0 ] || _THL_START_W=0
    return 0
}

# _thl_wait_for_start <cap> — wait until the start width is at least 1; THL_EXIT_WAIT_CAP at the cap.
_thl_wait_for_start() {
    local cap="$1" start="$SECONDS" waited nap noticed=0 interval
    _thl_int "${TEST_LANES_WAIT_INTERVAL:-}" "$THL_WAIT_INTERVAL_DEFAULT"
    interval="$_THL_INT"
    while :; do
        _thl_start_width
        [ "$_THL_START_W" -gt 0 ] && return 0
        waited=$((SECONDS - start))
        [ "$waited" -ge "$cap" ] && return "$THL_EXIT_WAIT_CAP"
        if [ "$noticed" -eq 0 ]; then
            printf '[lanes] waiting for a free lane (%s runs share %s lanes)\n' "$_THL_SHARE_RUNS" "$_THL_SHARE_POOL" >&2
            noticed=1
        fi
        nap="$interval"
        [ $((cap - waited)) -lt "$nap" ] && nap=$((cap - waited))
        sleep "$nap"
    done
}

# thl_run_all_lease <desired-j> <remaining-deadline|0> [unlimited] — at least 1, at most
# min(4, desired, headroom) lanes from 1..N-1 (1..1 when N=1); later growth follows the load
# sample. Sets THL_GRANTED/THL_WIDTH/THL_NOTE. `unlimited` keeps the lane-pool bound when
# lanes are not applied.
thl_run_all_lease() {
    local desired="${1:-1}" deadline="${2:-0}" cap want t0 left rc top ss=""
    [[ $desired =~ ^[1-9][0-9]{0,4}$ ]] || desired=1
    THL_GRANTED="$desired"; THL_WIDTH="$desired"; THL_LANES_DEGRADED=0; THL_NOTE=""
    if _thl_disabled; then
        _thl_not_applied_note "$desired" "${3:-}"; THL_GRANTED="$_THL_NA_JOBS"; THL_WIDTH="$_THL_NA_JOBS"; return 0
    fi
    [ -n "$THL_CACHE_ROOT" ] || thl_init_dir
    thl_max_jobs_per_host
    _thl_lanes_for "$desired"
    _THL_LEASE_TOP="$_THL_TOP"; _THL_LEASE_WANT="$_THL_WANT"
    _thl_int "${TEST_LANES_WAIT_CAP:-}" "$THL_RUN_ALL_CAP"
    cap="$_THL_INT"
    if [[ $deadline =~ ^[1-9][0-9]{0,8}$ ]] && [ "$deadline" -lt "$cap" ]; then cap="$deadline"; fi
    # shellcheck disable=SC2034  # read by the run-all exit-4 message
    THL_WAIT_CAP_USED="$cap"
    _thl_now
    THL_TOKEN="$$.$THL_NOW.$RANDOM"; THL_PRESENCE_START="$THL_NOW"
    thl_presence_enter "$desired"
    _thl_heartbeat_start
    t0="$SECONDS"
    _thl_wait_for_start "$cap" || { rc=$?; THL_GRANTED=0; THL_WIDTH=0; return "$rc"; }
    want="$_THL_START_W"
    THL_PER_RUN_CAP="$want"
    left=$((cap - (SECONDS - t0)))
    [ "$left" -ge 1 ] || left=1
    thl_acquire run-all "$want" 1 "$_THL_LEASE_TOP" asc "$left"
    rc=$?
    # The exit-4 message names the whole cap, not the remainder thl_acquire was given.
    # shellcheck disable=SC2034  # read by the run-all exit-4 message
    THL_WAIT_CAP_USED="$cap"
    [ "$rc" -eq 0 ] || return "$rc"
    # Without lanes nothing grows the width later, so a degraded lease runs at the full want.
    [ "$THL_LANES_DEGRADED" = 1 ] && THL_GRANTED="$_THL_LEASE_WANT"
    THL_WIDTH="$THL_GRANTED"
    TEST_LANES_HELD="$$"; export TEST_LANES_HELD
    _thl_source_text
    top="$desired"; [ "$top" -le "$_THL_LEASE_TOP" ] || top="$_THL_LEASE_TOP"
    [ "$THL_GRANTED" -lt "$top" ] && ss="; slow start from $THL_GRANTED, grows per run-all lane allocation sample"
    THL_NOTE="jobs $THL_GRANTED of requested $desired ($_THL_SRC; lanes ${THL_SLOTS:-none}$ss)${THL_RECORD_ADVICE:+; $THL_RECORD_ADVICE}"
    return 0
}

# _thl_acquire_more <kind> <target> <lo> <hi> <asc|desc> — grow the held set toward <target>
# with lanes free now (one reclaim sweep when short); never waits, keeps THL_TOKEN.
_thl_acquire_more() {
    local s="$THL_CACHE_ROOT/slots"
    [ "$THL_GRANTED" -lt "$2" ] || return 0
    _thl_claim_pass "$s" "$1" "$2" "$3" "$4" "$5"
    [ "$THL_GRANTED" -lt "$2" ] || return 0
    _thl_reclaim_sweep "$s" "$3" "$4" && _thl_claim_pass "$s" "$1" "$2" "$3" "$4" "$5"
    return 0
}

# _thl_release_lanes <count> — drop the highest-numbered held lanes; a lane re-taken by
# another token leaves THL_SLOTS but stays on disk.
_thl_release_lanes() {
    local k i top d rest
    for ((k = 0; k < $1; k++)); do
        top=""
        for i in $THL_SLOTS; do { [ -z "$top" ] || [ "$i" -gt "$top" ]; } && top="$i"; done
        [ -n "$top" ] || break
        d="$THL_CACHE_ROOT/slots/lane.$top"
        _thl_read_owner "$d" && [ "$_THL_O_TOKEN" = "$THL_TOKEN" ] && rm -rf "$d" 2>/dev/null
        rest=""
        for i in $THL_SLOTS; do [ "$i" = "$top" ] || rest="${rest:+$rest }$i"; done
        THL_SLOTS="$rest"
        THL_GRANTED=$((THL_GRANTED - 1))
    done
    return 0
}

# _thl_reb_sample — read the run-all lane allocation sample thl_rebalance follows: 0 when valid and fresh, 1 when
# valid but stale, 2 when unreadable or malformed.
_thl_reb_sample() {
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    _thl_sample_read "$THL_CACHE_ROOT/load/sample" || return 2
    _thl_sample_fresh "$_THL_INT"
}

# thl_sample_new — 0 when a fresh run-all lane allocation sample carries a measured_at the last thl_rebalance did
# not read (_THL_REB_AT); lets the run-all wait loop rebalance while every job still runs.
thl_sample_new() {
    [ -n "$THL_TOKEN" ] && [ "$THL_LANES_DEGRADED" != 1 ] || return 1
    _thl_reb_sample && [ "$_THL_S_AT" != "$_THL_REB_AT" ] && return 0
    return 1
}

# thl_rebalance <inflight> — move the held set toward the own row of a fresh run-all lane allocation sample
# (never below the running jobs; no row or no sample keeps the width) and set THL_WIDTH;
# prints one width line when THL_WIDTH changes. _THL_REB_ROW = 1 when the own row was used;
# _THL_REB_AT = the measured_at of the last valid sample read.
thl_rebalance() {
    local inflight="${1:-0}" old="$THL_WIDTH" target keep db=held memcap=none extra="" rs=0
    [ -n "$THL_TOKEN" ] || return 0
    [ "$THL_LANES_DEGRADED" = 1 ] && return 0
    [[ $inflight =~ ^[0-9]+$ ]] || inflight=0
    [ -d "$THL_CACHE_ROOT/runs/run.$THL_TOKEN" ] || thl_presence_enter "$_THL_OWN_DEMAND"
    _THL_REB_ROW=0; _THL_SHARE_SCALE=0
    target="$THL_WIDTH"
    _thl_reb_sample || rs=$?
    [ "$rs" = 2 ] || _THL_REB_AT="$_THL_S_AT"
    if [ "$rs" = 0 ]; then
        _THL_SHARE_RUNS="$_THL_S_RUNS"; _THL_SHARE_POOL="$_THL_S_POOL"; _THL_SHARE_SCALE="$_THL_S_SCALE"
        memcap="$_THL_S_MEM_CAP"
        if _thl_sample_row "$THL_TOKEN"; then
            target="$_THL_SR_W"; [ "$target" -le "$_THL_LEASE_WANT" ] || target="$_THL_LEASE_WANT"
            THL_PER_RUN_CAP="$_THL_SR_CAP"; db="$_THL_SR_BY"; _THL_REB_ROW=1
        elif [ -n "$THL_PRESENCE_START" ] && [ "$((10#$_THL_S_AT))" -lt "$THL_PRESENCE_START" ]; then
            db=slow-start
        fi
    fi
    if [ "$THL_GRANTED" -gt "$target" ]; then
        keep="$target"
        [ "$inflight" -gt "$keep" ] && keep="$inflight"
        [ "$THL_GRANTED" -gt "$keep" ] && _thl_release_lanes $((THL_GRANTED - keep))
    elif [ "$THL_GRANTED" -lt "$target" ]; then
        _thl_acquire_more run-all "$target" 1 "$_THL_LEASE_TOP" asc
    fi
    THL_WIDTH="$target"
    [ "$THL_GRANTED" -lt "$THL_WIDTH" ] && THL_WIDTH="$THL_GRANTED"
    [ "$THL_WIDTH" = "$old" ] && return 0
    case "${RUN_ALL_PROGRESS:-}" in off|OFF|0|false) return 0 ;; esac
    [ "$_THL_SHARE_SCALE" -gt 0 ] && extra=", load scale-in $_THL_SHARE_SCALE"
    [ "$memcap" != none ] && extra="$extra, memory cap $memcap"
    printf '[run-all] lanes: width %s -> %s (per-run lane cap %s among %s runs, decided by %s%s)\n' \
        "$old" "$THL_WIDTH" "$THL_PER_RUN_CAP" "$_THL_SHARE_RUNS" "$db" "$extra" >&2
    return 0
}

# thl_dispatch_wait [<deadline> <start>] — with nothing running and a width of 0, wait for the
# own row to turn positive (or, with no usable row, for the start-width rule to give a lane);
# no wait cap (the run is under way), but 1 once <deadline> seconds pass since <start>.
thl_dispatch_wait() {
    local deadline="${1:-0}" start="${2:-0}" interval
    [ -n "$THL_TOKEN" ] && [ "$THL_LANES_DEGRADED" != 1 ] || return 0
    [ "$THL_WIDTH" -lt 1 ] || return 0
    _thl_int "${TEST_LANES_WAIT_INTERVAL:-}" "$THL_WAIT_INTERVAL_DEFAULT"
    interval="$_THL_INT"
    printf '[lanes] per-run lane cap 0 among %s runs (pool %s lanes); waiting for a lane\n' "$_THL_SHARE_RUNS" "$_THL_SHARE_POOL" >&2
    while [ "$THL_WIDTH" -lt 1 ]; do
        [ "$deadline" -gt 0 ] && [ $((SECONDS - start)) -ge "$deadline" ] && return 1
        sleep "$interval"
        thl_rebalance 0
        if [ "$THL_WIDTH" -lt 1 ] && [ "$_THL_REB_ROW" = 0 ]; then
            _thl_start_width
            if [ "$_THL_START_W" -ge 1 ]; then
                _thl_acquire_more run-all "$_THL_START_W" 1 "$_THL_LEASE_TOP" asc
                THL_WIDTH="$THL_GRANTED"
            fi
        fi
    done
    return 0
}
