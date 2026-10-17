#!/usr/bin/env bash
# Fair share of the run-all lane pool (#2687): every run-all keeps a presence record
# runs/run.<token>; the pool is split among the records in start order and each run-all
# re-evaluates its width at every entry-script end. Sourced by test-host-lanes.sh only.
# shellcheck disable=SC2034,SC2153  # globals shared with test-host-lanes.sh and its callers

THL_FAIR_SHARE=0
THL_WIDTH=0
THL_LANES_DEGRADED=0
THL_PRESENCE_START=""
_THL_OWN_DEMAND=1
_THL_LEASE_TOP=1
_THL_LEASE_WANT=1
_THL_SHARE_POS=0
_THL_SHARE_POOL=1
_THL_SHARE_RUNS=1
_THL_SHARE_SCALE=0

# _thl_fair_share_compute <pool> <pos> <demand...> — THL_FAIR_SHARE of the run at 0-based
# <pos> in start order: water-fill, the remainder going to the earliest runs.
_thl_fair_share_compute() {
    local pool="$1" pos="$2" n i q rem active give
    shift 2
    local -a dem=("$@") alloc=()
    n=${#dem[@]}
    THL_FAIR_SHARE=0
    [ "$pos" -lt "$n" ] || return 0
    if [ "$n" -gt "$pool" ]; then
        [ "$pos" -lt "$pool" ] && THL_FAIR_SHARE=1
        return 0
    fi
    for ((i = 0; i < n; i++)); do
        alloc[i]=0
        [[ ${dem[i]} =~ ^[1-9][0-9]*$ ]] || dem[i]=1
    done
    rem="$pool"
    while [ "$rem" -gt 0 ]; do
        active=0
        for ((i = 0; i < n; i++)); do [ "${alloc[i]}" -lt "${dem[i]}" ] && active=$((active + 1)); done
        [ "$active" -gt 0 ] || break
        q=$((rem / active))
        for ((i = 0; i < n && rem > 0; i++)); do
            [ "${alloc[i]}" -lt "${dem[i]}" ] || continue
            give="$q"
            [ "$give" -gt 0 ] || give=1
            [ "$give" -gt $((dem[i] - alloc[i])) ] && give=$((dem[i] - alloc[i]))
            alloc[i]=$((alloc[i] + give))
            rem=$((rem - give))
        done
    done
    THL_FAIR_SHARE="${alloc[pos]}"
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

# thl_run_all_lease <desired-j> <remaining-deadline|0> [unlimited] — at least 1, at most
# min(fair share, desired, N-1) lanes from 1..N-1 (1..1 when N=1). Sets THL_GRANTED/
# THL_WIDTH/THL_NOTE. `unlimited` keeps the lane-pool bound when lanes are not applied.
thl_run_all_lease() {
    local desired="${1:-1}" deadline="${2:-0}" cap want t0 left rc
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
    _thl_wait_for_share "$cap" || return $?
    want="$THL_FAIR_SHARE"
    [ "$want" -gt "$_THL_LEASE_WANT" ] && want="$_THL_LEASE_WANT"
    left=$((cap - (SECONDS - t0)))
    [ "$left" -ge 1 ] || left=1
    thl_acquire run-all "$want" 1 "$_THL_LEASE_TOP" asc "$left"
    rc=$?
    # The exit-4 message names the whole cap, not the remainder thl_acquire was given.
    # shellcheck disable=SC2034  # read by the run-all exit-4 message
    THL_WAIT_CAP_USED="$cap"
    [ "$rc" -eq 0 ] || return "$rc"
    THL_WIDTH="$THL_GRANTED"
    TEST_LANES_HELD="$$"; export TEST_LANES_HELD
    _thl_source_text
    THL_NOTE="jobs $THL_GRANTED of requested $desired ($_THL_SRC; lanes ${THL_SLOTS:-none})${THL_RECORD_ADVICE:+; $THL_RECORD_ADVICE}"
    return 0
}

# _thl_fair_share — THL_FAIR_SHARE of this run among the live presence records; stale
# records are reclaimed. Also sets _THL_SHARE_POS/POOL/RUNS/SCALE.
_thl_fair_share() {
    local r="$THL_CACHE_ROOT/runs" d tok base i j n ts tt td
    local -a st=() tk=() dm=()
    [ -d "$r/run.$THL_TOKEN" ] || thl_presence_enter "$_THL_OWN_DEMAND"
    base="$THL_MAX_JOBS_PER_HOST"
    st+=("$THL_PRESENCE_START"); tk+=("$THL_TOKEN"); dm+=("$_THL_OWN_DEMAND")
    for d in "$r"/run.*; do
        [ -d "$d" ] || continue
        tok="${d##*/run.}"
        [ "$tok" = "$THL_TOKEN" ] && continue
        _thl_lane_state "$d"
        case "$THL_STATE" in
            alive|foreign) ;;
            stale-*) _thl_reclaim_one "$d" "$_THL_O_TOKEN"; continue ;;
            *) continue ;;
        esac
        [ -n "$_THL_O_START" ] || continue
        st+=("$((10#$_THL_O_START))"); tk+=("${_THL_O_TOKEN:-$tok}"); dm+=("${_THL_O_MJPR:-1000}")
        [ -n "$_THL_O_MJPH" ] && [ "$_THL_O_MJPH" -lt "$base" ] && base="$_THL_O_MJPH"
    done
    n=${#st[@]}
    for ((i = 1; i < n; i++)); do
        ts="${st[i]}"; tt="${tk[i]}"; td="${dm[i]}"
        for ((j = i - 1; j >= 0; j--)); do
            if [ "${st[j]}" -gt "$ts" ] || { [ "${st[j]}" -eq "$ts" ] && [[ ${tk[j]} > $tt ]]; }; then
                st[j + 1]="${st[j]}"; tk[j + 1]="${tk[j]}"; dm[j + 1]="${dm[j]}"
            else
                break
            fi
        done
        st[j + 1]="$ts"; tk[j + 1]="$tt"; dm[j + 1]="$td"
    done
    for ((i = 0; i < n; i++)); do [ "${tk[i]}" = "$THL_TOKEN" ] && break; done
    _THL_SHARE_POS="$i"; _THL_SHARE_RUNS="$n"
    _THL_SHARE_POOL=1
    [ "$base" -ge 2 ] && _THL_SHARE_POOL=$((base - 1))
    thl_load_scale_in
    _THL_SHARE_SCALE="$THL_LOAD_SCALE_IN"
    _THL_SHARE_POOL=$((_THL_SHARE_POOL - _THL_SHARE_SCALE))
    [ "$_THL_SHARE_POOL" -ge 1 ] || _THL_SHARE_POOL=1
    _thl_fair_share_compute "$_THL_SHARE_POOL" "$_THL_SHARE_POS" "${dm[@]}"
}

# _thl_wait_for_share <cap> — wait until the fair share is at least 1; THL_EXIT_WAIT_CAP at the cap.
_thl_wait_for_share() {
    local cap="$1" start="$SECONDS" waited nap noticed=0 interval
    _thl_int "${TEST_LANES_WAIT_INTERVAL:-}" "$THL_WAIT_INTERVAL_DEFAULT"
    interval="$_THL_INT"
    while :; do
        _thl_fair_share
        [ "$THL_FAIR_SHARE" -gt 0 ] && return 0
        waited=$((SECONDS - start))
        [ "$waited" -ge "$cap" ] && return "$THL_EXIT_WAIT_CAP"
        if [ "$noticed" -eq 0 ]; then
            printf '[lanes] waiting for a fair share (%s runs ahead share %s lanes)\n' "$_THL_SHARE_POS" "$_THL_SHARE_POOL" >&2
            noticed=1
        fi
        nap="$interval"
        [ $((cap - waited)) -lt "$nap" ] && nap=$((cap - waited))
        sleep "$nap"
    done
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

# thl_rebalance <inflight> — move the held set toward the fair share (never below the
# running jobs) and set THL_WIDTH; prints one width line when THL_WIDTH changes.
thl_rebalance() {
    local inflight="${1:-0}" old="$THL_WIDTH" target keep scale=""
    [ -n "$THL_TOKEN" ] || return 0
    [ "$THL_LANES_DEGRADED" = 1 ] && return 0
    [[ $inflight =~ ^[0-9]+$ ]] || inflight=0
    _thl_fair_share
    target="$THL_FAIR_SHARE"
    [ "$target" -gt "$_THL_LEASE_WANT" ] && target="$_THL_LEASE_WANT"
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
    [ "$_THL_SHARE_SCALE" -gt 0 ] && scale=", load scale-in $_THL_SHARE_SCALE"
    printf '[run-all] lanes: width %s -> %s (fair share among %s runs%s)\n' "$old" "$THL_WIDTH" "$_THL_SHARE_RUNS" "$scale" >&2
    return 0
}

# thl_dispatch_wait [<deadline> <start>] — with nothing running and a width of 0, wait for a
# fair share; no wait cap (the run is under way), but 1 once <deadline> seconds pass since <start>.
thl_dispatch_wait() {
    local deadline="${1:-0}" start="${2:-0}" interval
    [ -n "$THL_TOKEN" ] && [ "$THL_LANES_DEGRADED" != 1 ] || return 0
    [ "$THL_WIDTH" -lt 1 ] || return 0
    _thl_int "${TEST_LANES_WAIT_INTERVAL:-}" "$THL_WAIT_INTERVAL_DEFAULT"
    interval="$_THL_INT"
    printf '[lanes] fair share 0 among %s runs (pool %s lanes); waiting for a lane\n' "$_THL_SHARE_RUNS" "$_THL_SHARE_POOL" >&2
    while [ "$THL_WIDTH" -lt 1 ]; do
        [ "$deadline" -gt 0 ] && [ $((SECONDS - start)) -ge "$deadline" ] && return 1
        sleep "$interval"
        thl_rebalance 0
    done
    return 0
}
