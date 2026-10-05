#!/usr/bin/env bash
# Host-wide test lanes (#2455): one max jobs per host N of mkdir slots shared by every
# find-tests and run-all process on this host. Sourced only; requires
# bin/lib/run-all-parallelism.sh first. Plain globals only (no declare): run-all
# sources this file inside a function. Design: docs/architecture/claude-code/test-host-lanes.md.

THL_EXIT_WAIT_CAP=4
THL_TTL_DEFAULT=600
THL_HEARTBEAT_DEFAULT=60
THL_WAIT_INTERVAL_DEFAULT=2
THL_OWNERLESS_GRACE=2
THL_FIND_TESTS_CAP=540
THL_RUN_ALL_CAP=1800

THL_CACHE_ROOT=""
THL_HB_PID=""
THL_SLOTS=""
THL_TOKEN=""
THL_GRANTED=0
THL_NOTE=""
THL_WAIT_CAP_USED=0
THL_MAX_JOBS_PER_HOST=""
THL_MAX_JOBS_PER_HOST_SOURCE=""
THL_RECORD_REASON=""
THL_RECORD_OS=""
THL_OS_NOW=""
THL_RECORD_ADVICE=""
THL_PLAN_JOBS=0
THL_STATE=""
THL_AGE="-"
THL_NOW=0

# _thl_int <value> <default> — _THL_INT = value when a positive integer, else default.
_thl_int() {
    if [[ ${1:-} =~ ^[1-9][0-9]{0,6}$ ]]; then _THL_INT="$1"; else _THL_INT="$2"; fi
}

# _thl_now — THL_NOW = epoch seconds; the date fork is the bash < 4.2 fallback only.
_thl_now() {
    if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
        printf -v THL_NOW '%(%s)T' -1
    else
        THL_NOW="$(date +%s)"
    fi
}

# thl_init_dir — pin the cache root as an absolute path before any cd (a relative
# RUN_ALL_CACHE_DIR resolves against the caller's cwd, once per process).
thl_init_dir() {
    local d
    d="$(run_all_cache_dir)"
    case "$d" in
        [/]*|[A-Za-z]:*) ;;
        *) d="$PWD/$d" ;;
    esac
    THL_CACHE_ROOT="$d"
    if [ -n "${RUN_ALL_CACHE_DIR:-}" ]; then RUN_ALL_CACHE_DIR="$d"; export RUN_ALL_CACHE_DIR; fi
    return 0
}

# thl_max_jobs_per_host — THL_MAX_JOBS_PER_HOST / _SOURCE (env|dotenv|measured|default),
# first valid layer wins. An invalid value skips its layer with one fixed notice
# that never echoes it. A valid env value launches no .env resolver.
thl_max_jobs_per_host() {
    THL_RECORD_REASON=""; THL_RECORD_OS=""; THL_OS_NOW=""; THL_RECORD_ADVICE=""
    if [ -n "${TEST_MAX_JOBS_PER_HOST:-}" ]; then
        if run_all_valid_max_jobs "$TEST_MAX_JOBS_PER_HOST"; then
            THL_MAX_JOBS_PER_HOST="$((10#$TEST_MAX_JOBS_PER_HOST))"; THL_MAX_JOBS_PER_HOST_SOURCE="env"; return 0
        fi
        printf '[lanes] TEST_MAX_JOBS_PER_HOST is not an integer between 1 and 1024; ignored\n' >&2
    fi
    run_all_dotenv_value TEST_MAX_JOBS_PER_HOST
    if [ -n "$RUN_ALL_DOTENV_VALUE" ]; then
        if run_all_valid_max_jobs "$RUN_ALL_DOTENV_VALUE"; then
            THL_MAX_JOBS_PER_HOST="$((10#$RUN_ALL_DOTENV_VALUE))"; THL_MAX_JOBS_PER_HOST_SOURCE=dotenv; return 0
        fi
        printf '[lanes] TEST_MAX_JOBS_PER_HOST in .env is not an integer between 1 and 1024; ignored\n' >&2
    fi
    if run_all_cache_read "$(run_all_cache_file)" 2>/dev/null; then
        THL_MAX_JOBS_PER_HOST="$RUN_ALL_CACHE_MAX_JOBS_PER_HOST"; THL_MAX_JOBS_PER_HOST_SOURCE=measured
        THL_RECORD_OS="$RUN_ALL_CACHE_OS"
        THL_OS_NOW="$(run_all_os_attr)"
        [ "$THL_RECORD_OS" = "$THL_OS_NOW" ] ||
            THL_RECORD_ADVICE="measured on $THL_RECORD_OS, now $THL_OS_NOW; re-run $RUN_ALL_CALIBRATOR_HINT"
        return 0
    fi
    THL_MAX_JOBS_PER_HOST="$RUN_ALL_DEFAULT_MAX_JOBS_PER_HOST"; THL_MAX_JOBS_PER_HOST_SOURCE=default
    THL_RECORD_REASON="${RUN_ALL_CACHE_REASON:-missing}"
}

# _thl_lanes_for <requested> — the one width rule: _THL_TOP = H-1 (1 when H<2),
# _THL_WANT = min(requested, _THL_TOP), at least 1.
_thl_lanes_for() {
    local req="${1:-1}"
    [[ $req =~ ^[1-9][0-9]{0,4}$ ]] || req=1
    _THL_TOP=1
    [ "$THL_MAX_JOBS_PER_HOST" -ge 2 ] && _THL_TOP=$((THL_MAX_JOBS_PER_HOST - 1))
    _THL_WANT="$req"
    [ "$_THL_WANT" -gt "$_THL_TOP" ] && _THL_WANT="$_THL_TOP"
    return 0
}

# _thl_source_text — `max jobs per host <H>, source <s>[, record <reason>; calibrate with <hint>]`.
_thl_source_text() {
    _THL_SRC="max jobs per host $THL_MAX_JOBS_PER_HOST, source $THL_MAX_JOBS_PER_HOST_SOURCE"
    [ "$THL_MAX_JOBS_PER_HOST_SOURCE" = default ] &&
        _THL_SRC="$_THL_SRC, record $THL_RECORD_REASON; calibrate with $RUN_ALL_CALIBRATOR_HINT"
    return 0
}

# _thl_not_applied_note <requested> — THL_NOTE for a disabled lease (TEST_LANES=off named first).
_thl_not_applied_note() {
    local why="nested under a lane holder"
    [ "${TEST_LANES:-}" = off ] && why="TEST_LANES=off"
    THL_NOTE="not applied ($why); jobs $1 as requested"
}

# _thl_read_owner <lane-dir> — non-evaluating owner/hb reader. Sets _THL_O_*;
# every numeric field is validated before any arithmetic. 0 only with a valid pid.
_thl_read_owner() {
    local d="$1" line k v
    _THL_O_PID=""; _THL_O_ENV=""; _THL_O_KIND=""; _THL_O_START=""; _THL_O_TOKEN=""; _THL_O_HB=""
    [ -f "$d/owner" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            pid) [[ $v =~ ^[1-9][0-9]{0,9}$ ]] && _THL_O_PID="$v" ;;
            env) _THL_O_ENV="$v" ;;
            kind) _THL_O_KIND="$v" ;;
            start) [[ $v =~ ^[0-9]{1,12}$ ]] && _THL_O_START="$v" ;;
            token) [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && _THL_O_TOKEN="$v" ;;
        esac
    done 2>/dev/null < "$d/owner"
    if [ -f "$d/hb" ]; then
        line=""
        { IFS= read -r line < "$d/hb"; } 2>/dev/null
        [[ $line =~ ^[0-9]{1,12}$ ]] && _THL_O_HB="$line"
    fi
    [ -n "$_THL_O_PID" ]
}

# _thl_lane_state <lane-dir> — THL_STATE (alive|stale-dead-pid|stale-ttl|foreign|
# ownerless) and THL_AGE (seconds since hb, else start; "-" when neither is valid).
_thl_lane_state() {
    local ts old=0
    THL_AGE="-"
    if ! _thl_read_owner "$1"; then THL_STATE=ownerless; return 0; fi
    _thl_int "${TEST_LANES_TTL:-}" "$THL_TTL_DEFAULT"
    ts="${_THL_O_HB:-$_THL_O_START}"
    _thl_now
    if [ -n "$ts" ]; then
        THL_AGE=$((THL_NOW - 10#$ts))
        [ "$THL_AGE" -ge 0 ] || THL_AGE=0
        [ "$THL_AGE" -gt "$_THL_INT" ] && old=1
    else
        old=1
    fi
    if [ "$_THL_O_ENV" = "${OSTYPE:-}" ]; then
        if ! kill -0 "$_THL_O_PID" 2>/dev/null; then THL_STATE=stale-dead-pid
        elif [ "$old" -eq 1 ]; then THL_STATE=stale-ttl
        else THL_STATE=alive
        fi
    elif [ "$old" -eq 1 ]; then THL_STATE=stale-ttl
    else THL_STATE=foreign
    fi
}

# _thl_claim <slots-dir> <i> <kind> — take lane.<i> when it is free (0 on success).
_thl_claim() {
    local d="$1/lane.$2"
    [ -d "$d" ] && return 1
    mkdir "$d" 2>/dev/null || return 1
    { printf 'pid=%s\nenv=%s\nkind=%s\nstart=%s\ntoken=%s\n' "$$" "${OSTYPE:-}" "$3" "$THL_NOW" "$THL_TOKEN" > "$d/owner"; } 2>/dev/null
    { printf '%s\n' "$THL_NOW" > "$d/hb"; } 2>/dev/null
    THL_SLOTS="${THL_SLOTS:+$THL_SLOTS }$2"
    THL_GRANTED=$((THL_GRANTED + 1))
}

# _thl_claim_pass <slots> <kind> <want> <lo> <hi> <asc|desc>
_thl_claim_pass() {
    local s="$1" kind="$2" want="$3" lo="$4" hi="$5" i
    _thl_now
    if [ "$6" = desc ]; then
        for ((i = hi; i >= lo && THL_GRANTED < want; i--)); do _thl_claim "$s" "$i" "$kind"; done
    else
        for ((i = lo; i <= hi && THL_GRANTED < want; i++)); do _thl_claim "$s" "$i" "$kind"; done
    fi
    return 0
}

# _thl_reclaim_sweep <slots> <lo> <hi> — reclaim stale lanes in range; 0 when any
# was reclaimed. Token re-check, then an atomic mv to a grave, then rm.
_thl_reclaim_sweep() {
    local s="$1" lo="$2" hi="$3" i d tok g any=1
    for ((i = lo; i <= hi; i++)); do
        d="$s/lane.$i"
        [ -d "$d" ] || { unset '_THL_SEEN[i]'; continue; }
        _thl_lane_state "$d"
        case "$THL_STATE" in
            ownerless)
                if [ -z "${_THL_SEEN[i]:-}" ]; then _THL_SEEN[i]="$SECONDS"; continue; fi
                [ $((SECONDS - _THL_SEEN[i])) -ge "$THL_OWNERLESS_GRACE" ] || continue
                _thl_read_owner "$d" && continue ;;
            stale-*)
                unset '_THL_SEEN[i]'
                tok="$_THL_O_TOKEN"
                _thl_read_owner "$d"
                [ "$_THL_O_TOKEN" = "$tok" ] || continue ;;
            *) unset '_THL_SEEN[i]'; continue ;;
        esac
        g="$s/.grave.$i.$$.$RANDOM"
        mv "$d" "$g" 2>/dev/null || continue
        rm -rf "$g" 2>/dev/null
        unset '_THL_SEEN[i]'
        any=0
    done
    return "$any"
}

# thl_acquire <kind> <want> <lo> <hi> <asc|desc> <wait-cap> — the first lane waits
# up to the cap; extra lanes are taken only when free now. Sets THL_GRANTED,
# THL_SLOTS, THL_TOKEN. Returns THL_EXIT_WAIT_CAP when no lane frees in time.
thl_acquire() {
    local kind="$1" want="$2" lo="$3" hi="$4" order="$5" cap="$6" s start waited nap noticed=0
    _thl_int "${TEST_LANES_WAIT_INTERVAL:-}" "$THL_WAIT_INTERVAL_DEFAULT"
    local interval="$_THL_INT"
    THL_GRANTED=0; THL_SLOTS=""
    # shellcheck disable=SC2034  # read by the find-tests / run-all exit-4 message
    THL_WAIT_CAP_USED="$cap"
    _thl_now
    THL_TOKEN="$$.$THL_NOW.$RANDOM"
    _THL_SEEN=()
    s="$THL_CACHE_ROOT/slots"
    [ -d "$s" ] || mkdir -p "$s" 2>/dev/null
    if [ ! -d "$s" ]; then
        printf '[lanes] cannot create %s; running without a lane\n' "$s" >&2
        THL_GRANTED="$want"; return 0
    fi
    start=$SECONDS
    while :; do
        _thl_claim_pass "$s" "$kind" "$want" "$lo" "$hi" "$order"
        [ "$THL_GRANTED" -ge "$want" ] && return 0
        _thl_reclaim_sweep "$s" "$lo" "$hi" && _thl_claim_pass "$s" "$kind" "$want" "$lo" "$hi" "$order"
        [ "$THL_GRANTED" -gt 0 ] && return 0
        waited=$((SECONDS - start))
        [ "$waited" -ge "$cap" ] && return "$THL_EXIT_WAIT_CAP"
        if [ "$noticed" -eq 0 ]; then
            printf '[lanes] all test lanes %s..%s busy; waiting up to %ss (inspect holders with: bash bin/test-lanes-status.sh)\n' "$lo" "$hi" "$cap" >&2
            noticed=1
        fi
        nap="$interval"
        [ $((cap - waited)) -lt "$nap" ] && nap=$((cap - waited))
        sleep "$nap"
    done
}

# _thl_hb_refresh — rewrite hb only on lanes whose owner token is still ours.
_thl_hb_refresh() {
    local i d
    _thl_now
    for i in $THL_SLOTS; do
        d="$THL_CACHE_ROOT/slots/lane.$i"
        _thl_read_owner "$d" || continue
        [ "$_THL_O_TOKEN" = "$THL_TOKEN" ] || continue
        { printf '%s\n' "$THL_NOW" > "$d/hb"; } 2>/dev/null
    done
}

# _thl_heartbeat_start — the one background process of the runner (fds detached;
# it exits with its parent or on TERM from thl_release_all).
_thl_heartbeat_start() {
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    local hb="$_THL_INT"
    (
        _s=""
        trap 'kill "$_s" 2>/dev/null; exit 0' TERM INT
        while kill -0 "$$" 2>/dev/null; do
            sleep "$hb" &
            _s=$!
            wait "$_s"
            _thl_hb_refresh
        done
    ) </dev/null >/dev/null 2>&1 &
    THL_HB_PID=$!
}

# thl_release_all — stop the heartbeat, remove only the lanes still carrying our
# token (one rm), clear the nested marker. Idempotent; always 0.
thl_release_all() {
    local i d
    local -a gone=()
    if [ -n "${THL_HB_PID:-}" ]; then
        case "$-" in
            *m*) kill -TERM -- "-$THL_HB_PID" 2>/dev/null || kill -TERM "$THL_HB_PID" 2>/dev/null ;;
            *) kill -TERM "$THL_HB_PID" 2>/dev/null ;;
        esac
        wait "$THL_HB_PID" 2>/dev/null
        THL_HB_PID=""
    fi
    if [ -n "${THL_SLOTS:-}" ] && [ -n "${THL_CACHE_ROOT:-}" ]; then
        for i in $THL_SLOTS; do
            d="$THL_CACHE_ROOT/slots/lane.$i"
            _thl_read_owner "$d" && [ "$_THL_O_TOKEN" = "$THL_TOKEN" ] && gone+=("$d")
        done
        [ "${#gone[@]}" -gt 0 ] && rm -rf "${gone[@]}" 2>/dev/null
    fi
    THL_SLOTS=""
    [ "${TEST_LANES_HELD:-}" = "$$" ] && unset TEST_LANES_HELD
    return 0
}

# _thl_disabled — 0 when lanes are off or an ancestor already holds one.
_thl_disabled() {
    [ "${TEST_LANES:-}" = off ] || [ -n "${TEST_LANES_HELD:-}" ]
}

# thl_find_tests_lease — one lane, scanned from lane N down (lane N is the one
# run-all never takes). Returns THL_EXIT_WAIT_CAP at the cap.
thl_find_tests_lease() {
    _thl_disabled && return 0
    [ -n "$THL_CACHE_ROOT" ] || thl_init_dir
    thl_max_jobs_per_host
    _thl_int "${TEST_LANES_WAIT_CAP:-}" "$THL_FIND_TESTS_CAP"
    thl_acquire find-tests 1 1 "$THL_MAX_JOBS_PER_HOST" desc "$_THL_INT" || return $?
    TEST_LANES_HELD="$$"; export TEST_LANES_HELD
}

# thl_run_all_lease <desired-j> <remaining-deadline|0> — at least 1, at most
# min(desired, N-1) lanes from 1..N-1 (1..1 when N=1). Sets THL_GRANTED/THL_NOTE.
thl_run_all_lease() {
    local desired="${1:-1}" deadline="${2:-0}" cap
    [[ $desired =~ ^[1-9][0-9]{0,4}$ ]] || desired=1
    THL_GRANTED="$desired"; THL_NOTE=""
    if _thl_disabled; then _thl_not_applied_note "$desired"; return 0; fi
    [ -n "$THL_CACHE_ROOT" ] || thl_init_dir
    thl_max_jobs_per_host
    _thl_lanes_for "$desired"
    _thl_int "${TEST_LANES_WAIT_CAP:-}" "$THL_RUN_ALL_CAP"
    cap="$_THL_INT"
    if [[ $deadline =~ ^[1-9][0-9]{0,8}$ ]] && [ "$deadline" -lt "$cap" ]; then cap="$deadline"; fi
    thl_acquire run-all "$_THL_WANT" 1 "$_THL_TOP" asc "$cap" || return $?
    [ -n "$THL_SLOTS" ] && _thl_heartbeat_start
    TEST_LANES_HELD="$$"; export TEST_LANES_HELD
    _thl_source_text
    THL_NOTE="jobs $THL_GRANTED of requested $desired ($_THL_SRC; lanes ${THL_SLOTS:-none})${THL_RECORD_ADVICE:+; $THL_RECORD_ADVICE}"
    return 0
}

# thl_plan <requested> — the width a lease would ask for, without taking one
# (--print-plan). Sets THL_PLAN_JOBS and THL_NOTE.
thl_plan() {
    local req="${1:-1}"
    [[ $req =~ ^[1-9][0-9]{0,4}$ ]] || req=1
    THL_PLAN_JOBS="$req"
    if _thl_disabled; then _thl_not_applied_note "$req"; return 0; fi
    thl_max_jobs_per_host
    _thl_lanes_for "$req"
    THL_PLAN_JOBS="$_THL_WANT"
    _thl_source_text
    # shellcheck disable=SC2034  # read by tests/run-all.sh's `plan:` / `lanes:` progress lines
    THL_NOTE="jobs $THL_PLAN_JOBS of requested $req ($_THL_SRC; a live lease may grant fewer)${THL_RECORD_ADVICE:+; $THL_RECORD_ADVICE}"
    return 0
}

# thl_status — read-only listing for bin/test-lanes-status.sh; never reclaims.
# Line 1 never shows host_id or measured_at; `os` is shown only after its shape check.
thl_status() {
    local d i n=0 line
    thl_max_jobs_per_host
    line="max_jobs_per_host=$THL_MAX_JOBS_PER_HOST source=$THL_MAX_JOBS_PER_HOST_SOURCE"
    [ "$THL_MAX_JOBS_PER_HOST_SOURCE" = default ] && line="$line record=$THL_RECORD_REASON"
    [ -n "$THL_RECORD_ADVICE" ] && line="$line measured_on=$THL_RECORD_OS now=$THL_OS_NOW"
    printf '%s\n' "$line"
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
        printf 'lane.%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "${_THL_O_KIND//[!A-Za-z0-9._-]/?}" \
            "$_THL_O_PID" "${_THL_O_ENV//[!A-Za-z0-9._-]/?}" "$THL_AGE" "$THL_STATE"
    done
    [ "$n" -gt 0 ] || printf 'no test lanes held\n'
    return 0
}
