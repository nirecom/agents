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
THL_RECALIBRATE=""
THL_CAP_NOTE=""
THL_AUTO_CONFIG="on"
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

# _thl_pin — _THL_PIN / _THL_PIN_SRC: the first valid pin (env, then .env), empty when none.
# An invalid value skips its layer with one fixed notice that never echoes it; a valid env
# value launches no .env resolver.
_thl_pin() {
    _THL_PIN=""; _THL_PIN_SRC=""
    if [ -n "${TEST_MAX_JOBS_PER_HOST:-}" ]; then
        if run_all_valid_max_jobs "$TEST_MAX_JOBS_PER_HOST"; then
            _THL_PIN="$((10#$TEST_MAX_JOBS_PER_HOST))"; _THL_PIN_SRC="env"; return 0
        fi
        printf '[lanes] TEST_MAX_JOBS_PER_HOST is not an integer between 1 and 1024; ignored\n' >&2
    fi
    run_all_dotenv_value TEST_MAX_JOBS_PER_HOST
    [ -n "$RUN_ALL_DOTENV_VALUE" ] || return 0
    if run_all_valid_max_jobs "$RUN_ALL_DOTENV_VALUE"; then
        _THL_PIN="$((10#$RUN_ALL_DOTENV_VALUE))"; _THL_PIN_SRC="dotenv"; return 0
    fi
    printf '[lanes] TEST_MAX_JOBS_PER_HOST in .env is not an integer between 1 and 1024; ignored\n' >&2
}

# _thl_record_advice — after a successful record read: THL_RECALIBRATE (legacy-record |
# cpu-count-changed | ladder-truncated, empty when the record still fits this host) and the
# THL_RECORD_ADVICE text. A knee at a corpus-narrowed widest width is noted, never asked.
_thl_record_advice() {
    local knee="$RUN_ALL_CACHE_MAX_JOBS_PER_HOST" rec="$RUN_ALL_CACHE_LOGICAL_CPU_COUNT"
    local widest="$RUN_ALL_CACHE_MAX_WIDTH_MEASURED" now="$RUN_ALL_LOGICAL_CPU_COUNT" text=""
    THL_RECORD_OS="$RUN_ALL_CACHE_OS"
    THL_OS_NOW="$(run_all_os_attr)"
    [ "$THL_RECORD_OS" != "$THL_OS_NOW" ] && text="measured on $THL_RECORD_OS, now $THL_OS_NOW"
    if [ "$RUN_ALL_CACHE_IS_LEGACY" = 1 ]; then
        THL_RECALIBRATE=legacy-record; text="${text:+$text; }the record predates schema 3"
    elif [ "$rec" != 0 ] && [ -n "$now" ] && [ "$rec" != "$now" ]; then
        THL_RECALIBRATE=cpu-count-changed; text="${text:+$text; }measured at $rec logical CPUs, now $now"
    elif [ "$knee" = "$widest" ] && [ "$widest" -lt "$rec" ] && [ "$RUN_ALL_CACHE_WIDTH_LIMIT" = jobs-list ]; then
        THL_RECALIBRATE=ladder-truncated; text="${text:+$text; }the knee is the widest measured width $widest"
    fi
    if [ -n "$text" ]; then
        THL_RECORD_ADVICE="$text; re-run $RUN_ALL_CALIBRATOR_HINT"
    elif [ "$knee" = "$widest" ] && [ "$widest" -lt "${now:-$rec}" ]; then
        case "$RUN_ALL_CACHE_WIDTH_LIMIT" in candidates|sample|time-limit) THL_RECORD_ADVICE="measured up to $widest" ;; esac
    fi
    return 0
}

# thl_max_jobs_per_host — THL_MAX_JOBS_PER_HOST / _SOURCE (env|dotenv|measured|default) under
# THL_AUTO_CONFIG. Off: the pin, else the default; the record is never read. On: min(pin,
# base), base = the record, else the default; a tie reports the base, and the record's advice
# survives only while it is the source. Either way capped at the logical CPU count (THL_CAP_NOTE).
thl_max_jobs_per_host() {
    THL_RECORD_REASON=""; THL_RECORD_OS=""; THL_OS_NOW=""; THL_RECORD_ADVICE=""; THL_RECALIBRATE=""; THL_CAP_NOTE=""
    run_all_auto_config; THL_AUTO_CONFIG="$RUN_ALL_AUTO_CONFIG"
    run_all_logical_cpu_count
    _thl_pin
    THL_MAX_JOBS_PER_HOST="$RUN_ALL_DEFAULT_MAX_JOBS_PER_HOST"; THL_MAX_JOBS_PER_HOST_SOURCE=default
    if [ "$THL_AUTO_CONFIG" = off ]; then
        [ -n "$_THL_PIN" ] && { THL_MAX_JOBS_PER_HOST="$_THL_PIN"; THL_MAX_JOBS_PER_HOST_SOURCE="$_THL_PIN_SRC"; }
    else
        if run_all_cache_read "$(run_all_cache_file)" 2>/dev/null; then
            THL_MAX_JOBS_PER_HOST="$RUN_ALL_CACHE_MAX_JOBS_PER_HOST"; THL_MAX_JOBS_PER_HOST_SOURCE=measured
            _thl_record_advice
        else
            THL_RECORD_REASON="${RUN_ALL_CACHE_REASON:-missing}"
        fi
        if [ -n "$_THL_PIN" ] && [ "$_THL_PIN" -lt "$THL_MAX_JOBS_PER_HOST" ]; then
            THL_MAX_JOBS_PER_HOST="$_THL_PIN"; THL_MAX_JOBS_PER_HOST_SOURCE="$_THL_PIN_SRC"
            THL_RECORD_REASON=""; THL_RECORD_OS=""; THL_OS_NOW=""; THL_RECORD_ADVICE=""; THL_RECALIBRATE=""
        fi
    fi
    if [ -z "$RUN_ALL_LOGICAL_CPU_COUNT" ]; then
        THL_CAP_NOTE="logical CPU count unknown; not capped"
    elif [ "$THL_MAX_JOBS_PER_HOST" -gt "$RUN_ALL_LOGICAL_CPU_COUNT" ]; then
        THL_MAX_JOBS_PER_HOST="$RUN_ALL_LOGICAL_CPU_COUNT"
        THL_CAP_NOTE="capped at logical CPU count $RUN_ALL_LOGICAL_CPU_COUNT"
    fi
    return 0
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

# _thl_source_text — `max jobs per host <n>, source <s>[, <cap note>][, record <reason>;
# calibrate with <hint>]`; the record part appears only when on mode fell back to the default.
_thl_source_text() {
    _THL_SRC="max jobs per host $THL_MAX_JOBS_PER_HOST, source $THL_MAX_JOBS_PER_HOST_SOURCE${THL_CAP_NOTE:+, $THL_CAP_NOTE}"
    if [ "$THL_MAX_JOBS_PER_HOST_SOURCE" = default ] && [ -n "$THL_RECORD_REASON" ]; then
        _THL_SRC="$_THL_SRC, record $THL_RECORD_REASON; calibrate with $RUN_ALL_CALIBRATOR_HINT"
    fi
    return 0
}

# _thl_not_applied_note <requested> [unlimited] — THL_NOTE and _THL_NA_JOBS for a disabled
# lease (TEST_LANES=off named first). An explicit request is kept as is; an unlimited max
# jobs per run is still bounded by the run-all lane pool.
_thl_not_applied_note() {
    local why="nested under a lane holder"
    [ "${TEST_LANES:-}" = off ] && why="TEST_LANES=off"
    _THL_NA_JOBS="$1"
    if [ "${2:-}" = unlimited ]; then
        thl_max_jobs_per_host; _thl_lanes_for "$1"; _THL_NA_JOBS="$_THL_WANT"
        THL_NOTE="not applied ($why); jobs $_THL_NA_JOBS (max jobs per run unlimited, bounded by the run-all lane pool)"
        return 0
    fi
    THL_NOTE="not applied ($why); jobs $1 as requested"
}

# _thl_read_owner <lane-dir> — non-evaluating owner/hb reader. Sets _THL_O_*;
# every numeric field is validated before any arithmetic. 0 only with a valid pid.
_thl_read_owner() {
    local d="$1" line k v
    _THL_O_PID=""; _THL_O_ENV=""; _THL_O_KIND=""; _THL_O_START=""; _THL_O_TOKEN=""; _THL_O_HB=""
    _THL_O_MJPR=""; _THL_O_MJPH=""
    [ -f "$d/owner" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            pid) [[ $v =~ ^[1-9][0-9]{0,9}$ ]] && _THL_O_PID="$v" ;;
            env) _THL_O_ENV="$v" ;;
            kind) _THL_O_KIND="$v" ;;
            start) [[ $v =~ ^[0-9]{1,12}$ ]] && _THL_O_START="$v" ;;
            token) [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && _THL_O_TOKEN="$v" ;;
            max_jobs_per_run) [[ $v =~ ^[1-9][0-9]{0,6}$ ]] && _THL_O_MJPR="$v" ;;
            max_jobs_per_host) [[ $v =~ ^[1-9][0-9]{0,6}$ ]] && _THL_O_MJPH="$v" ;;
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

# _thl_reclaim_one <dir> <token> [ownerless] — re-read the owner; when its token is still
# <token> (or it is still ownerless), an atomic mv to a sibling grave, then rm. 0 when reclaimed.
_thl_reclaim_one() {
    local d="$1" g
    if [ "${3:-}" = ownerless ]; then
        _thl_read_owner "$d" && return 1
    else
        _thl_read_owner "$d"
        [ "$_THL_O_TOKEN" = "$2" ] || return 1
    fi
    g="${d%/*}/.grave.${d##*/}.$$.$RANDOM"
    mv "$d" "$g" 2>/dev/null || return 1
    rm -rf "$g" 2>/dev/null
    return 0
}

# _thl_reclaim_sweep <slots> <lo> <hi> — reclaim stale lanes in range; 0 when any was reclaimed.
_thl_reclaim_sweep() {
    local s="$1" lo="$2" hi="$3" i d tok how any=1
    for ((i = lo; i <= hi; i++)); do
        d="$s/lane.$i"
        [ -d "$d" ] || { unset '_THL_SEEN[i]'; continue; }
        _thl_lane_state "$d"
        case "$THL_STATE" in
            ownerless)
                if [ -z "${_THL_SEEN[i]:-}" ]; then _THL_SEEN[i]="$SECONDS"; continue; fi
                [ $((SECONDS - _THL_SEEN[i])) -ge "$THL_OWNERLESS_GRACE" ] || continue
                tok=""; how=ownerless ;;
            stale-*) unset '_THL_SEEN[i]'; tok="$_THL_O_TOKEN"; how="" ;;
            *) unset '_THL_SEEN[i]'; continue ;;
        esac
        _thl_reclaim_one "$d" "$tok" "$how" || continue
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
    [ -n "$THL_TOKEN" ] || THL_TOKEN="$$.$THL_NOW.$RANDOM"
    _THL_SEEN=()
    s="$THL_CACHE_ROOT/slots"
    [ -d "$s" ] || mkdir -p "$s" 2>/dev/null
    if [ ! -d "$s" ]; then
        printf '[lanes] cannot create %s; running without a lane\n' "$s" >&2
        THL_GRANTED="$want"; THL_LANES_DEGRADED=1; return 0
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

# _thl_hb_refresh — rewrite hb on every lane and presence record whose owner token is
# ours (scanned, so lanes taken after the heartbeat started are covered too).
_thl_hb_refresh() {
    local d
    [ -n "$THL_TOKEN" ] || return 0
    _thl_now
    for d in "$THL_CACHE_ROOT"/slots/lane.* "$THL_CACHE_ROOT/runs/run.$THL_TOKEN"; do
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
        _s=""; _l=""
        trap 'kill "$_s" "$_l" 2>/dev/null; exit 0' TERM INT
        while kill -0 "$$" 2>/dev/null; do
            _thl_hb_refresh
            # The load tick runs beside the heartbeat (one at a time), so a slow probe
            # never delays a refresh past the stale limit.
            if ! { [ -n "$_l" ] && kill -0 "$_l" 2>/dev/null; }; then
                thl_load_tick &
                _l=$!
            fi
            sleep "$hb" &
            _s=$!
            wait "$_s"
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
    fi
    if [ -n "${THL_TOKEN:-}" ] && [ -n "${THL_CACHE_ROOT:-}" ]; then
        d="$THL_CACHE_ROOT/runs/run.$THL_TOKEN"
        _thl_read_owner "$d" && [ "$_THL_O_TOKEN" = "$THL_TOKEN" ] && gone+=("$d")
    fi
    [ "${#gone[@]}" -gt 0 ] && rm -rf "${gone[@]}" 2>/dev/null
    THL_SLOTS=""; THL_TOKEN=""; THL_PRESENCE_START=""; THL_LANES_DEGRADED=0
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

# thl_plan <requested> [unlimited] — the width a lease would ask for, without taking one
# (--print-plan). Sets THL_PLAN_JOBS and THL_NOTE.
thl_plan() {
    local req="${1:-1}"
    [[ $req =~ ^[1-9][0-9]{0,4}$ ]] || req=1
    THL_PLAN_JOBS="$req"
    if _thl_disabled; then _thl_not_applied_note "$req" "${2:-}"; THL_PLAN_JOBS="$_THL_NA_JOBS"; return 0; fi
    thl_max_jobs_per_host
    _thl_lanes_for "$req"
    THL_PLAN_JOBS="$_THL_WANT"
    _thl_source_text
    # shellcheck disable=SC2034  # read by tests/run-all.sh's `plan:` / `lanes:` progress lines
    THL_NOTE="jobs $THL_PLAN_JOBS of requested $req ($_THL_SRC; starts at up to 4 and grows per run-all lane allocation sample (slow start); re-evaluated at each entry-script end; running jobs are never stopped, so a run may hold more than its per-run lane cap until they finish)${THL_RECORD_ADVICE:+; $THL_RECORD_ADVICE}"
    return 0
}

# The probe, run-all lane allocation sample, load, per-run lane cap, allocation (#2687, #2692) and status libraries,
# found next to this file.
_THL_LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$_THL_LIB_DIR" = "${BASH_SOURCE[0]}" ] && _THL_LIB_DIR="."
# shellcheck source=bin/lib/test-host-load-probe.sh
. "$_THL_LIB_DIR/test-host-load-probe.sh"
# shellcheck source=bin/lib/test-host-load-sample.sh
. "$_THL_LIB_DIR/test-host-load-sample.sh"
# shellcheck source=bin/lib/test-host-load.sh
. "$_THL_LIB_DIR/test-host-load.sh"
# shellcheck source=bin/lib/test-host-lanes-share.sh
. "$_THL_LIB_DIR/test-host-lanes-share.sh"
# shellcheck source=bin/lib/test-host-alloc.sh
. "$_THL_LIB_DIR/test-host-alloc.sh"
# shellcheck source=bin/lib/test-host-lanes-status.sh
. "$_THL_LIB_DIR/test-host-lanes-status.sh"
