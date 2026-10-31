#!/usr/bin/env bash
# Lane allocation (#2692): the load claim holder turns one measurement into every run-all's
# row `<w> <ss> <cap> <decided_by>` — the run-all per-run lane cap over the pool (CPU scale-in,
# memory cap), slow start growth (double below ssthresh, +1 at or above) only on a measured
# sample after a fresh one; a failed measurement or a stale sample keeps every width. Sourced by
# test-host-lanes.sh only.
# shellcheck disable=SC2034,SC2153  # _THL_S_* written for _thl_sample_write; _THL_M_* set by test-host-load.sh

THL_SLOW_START_INIT=4
THL_MEM_PER_LANE_FLOOR_MB=512
THL_MEM_RESERVE_FLOOR_MB=2048
THL_MEM_RESERVE_PCT=10

# _thl_alloc_mem <avail> <total> <tests> <held-lanes> — _THL_AM_RESERVE/CAP: below the reserve
# the lanes over it go (cap, at least 1); no cap above it or when memory is unmeasurable.
_thl_alloc_mem() {
    local av="$1" tt="$2" ts="$3" h="$4" per
    _THL_AM_RESERVE=unknown; _THL_AM_CAP=none
    [ "$av" = unknown ] && return 0
    _THL_AM_RESERVE="$THL_MEM_RESERVE_FLOOR_MB"
    if [ "$tt" != unknown ] && [ $((tt * THL_MEM_RESERVE_PCT / 100)) -gt "$_THL_AM_RESERVE" ]; then
        _THL_AM_RESERVE=$((tt * THL_MEM_RESERVE_PCT / 100))
    fi
    per="$THL_MEM_PER_LANE_FLOOR_MB"
    [ "$h" -gt 0 ] && [ $(((ts + h - 1) / h)) -gt "$per" ] && per=$(((ts + h - 1) / h))
    if [ "$av" -lt "$_THL_AM_RESERVE" ]; then
        _THL_AM_CAP=$((h - (_THL_AM_RESERVE - av + per - 1) / per))
        [ "$_THL_AM_CAP" -ge 1 ] || _THL_AM_CAP=1
    fi
    return 0
}

# _thl_alloc_held <top> — _THL_AH_TOKS (one token per live run-all lane), _THL_AH_N (their
# count) and _THL_AH_FREE (lanes 1..<top> without a directory).
_thl_alloc_held() {
    local d i
    _THL_AH_TOKS=""; _THL_AH_N=0; _THL_AH_FREE=0
    for d in "$THL_CACHE_ROOT"/slots/lane.*; do
        [ -d "$d" ] || continue
        _thl_lane_state "$d"
        case "$THL_STATE" in alive|foreign) ;; *) continue ;; esac
        [ "$_THL_O_KIND" = run-all ] || continue
        _THL_AH_TOKS="$_THL_AH_TOKS $_THL_O_TOKEN"; _THL_AH_N=$((_THL_AH_N + 1))
    done
    _THL_AH_TOKS="$_THL_AH_TOKS "
    for ((i = 1; i <= $1; i++)); do [ -d "$THL_CACHE_ROOT/slots/lane.$i" ] || _THL_AH_FREE=$((_THL_AH_FREE + 1)); done
    return 0
}

# _thl_alloc_count <token> — _THL_AC = the lanes of _THL_AH_TOKS held under <token>.
_thl_alloc_count() {
    local t
    _THL_AC=0
    for t in $_THL_AH_TOKS; do [ "$t" = "$1" ] && _THL_AC=$((_THL_AC + 1)); done
    return 0
}

# _thl_alloc_run <prev-fresh> [<gen1>] — from _THL_M_* (this measurement) and the previous sample
# in _THL_S_* (rows kept even when stale; growth only when <prev-fresh> is 1), set every _THL_S_*.
# <gen1> 1: the previous sample is generation 1, so a run holding lanes restarts from them.
_thl_alloc_run() {
    local pf="$1" g1="${2:-0}" base top ncpu reserved=0 excess cpupool pool i n tok ht w ss prc prc0 nw db grow_ok=0 row
    local rows="" cap av tt rs sc free
    local -a prca=() prc0a=()
    _THL_LS_SCALE="$_THL_S_SCALE"; _THL_LS_ABOVE="$_THL_S_ABOVE"; _THL_LS_BELOW="$_THL_S_BELOW"
    if [ "$pf" != 1 ] || [ "$_THL_M_STATE" != ok ]; then _THL_LS_SCALE=0; _THL_LS_ABOVE=0; _THL_LS_BELOW=0; fi
    _thl_presence_scan
    base="$_THL_PS_BASE"
    top=1; [ "$base" -ge 2 ] && top=$((base - 1))
    _thl_alloc_held "$top"; free="$_THL_AH_FREE"
    run_all_logical_cpu_count
    ncpu="${RUN_ALL_LOGICAL_CPU_COUNT:-}"
    [[ $ncpu =~ ^[0-9]+$ ]] && [ "$ncpu" -gt "$base" ] && reserved=$((ncpu - base))
    if [ "$_THL_M_STATE" = ok ]; then
        excess=$((_THL_M_EXT - reserved * 100)); [ "$excess" -ge 0 ] || excess=0
        _thl_load_hysteresis ok "$excess"
    fi
    cpupool=$((base - 1 - _THL_LS_SCALE)); [ "$cpupool" -ge 1 ] || cpupool=1
    av="$_THL_M_AVAIL"; tt="$_THL_M_TOTAL"; sc="$_THL_M_SCOPE"
    _thl_alloc_mem "$av" "$tt" "$_THL_M_TESTS" "$_THL_AH_N"
    rs="$_THL_AM_RESERVE"; cap="$_THL_AM_CAP"
    pool="$cpupool"
    [ "$cap" != none ] && [ "$cap" -lt "$pool" ] && pool="$cap"
    # Growth needs a fresh previous sample; mode off grows without a measurement.
    case "$pf:$_THL_M_STATE" in 1:ok|1:off) grow_ok=1 ;; esac
    n=${#_THL_PS_TK[@]}
    _thl_per_run_cap_all "$pool" ${_THL_PS_DM[@]+"${_THL_PS_DM[@]}"}; prca=(${THL_PRC_ALLOC[@]+"${THL_PRC_ALLOC[@]}"})
    _thl_per_run_cap_all "$top" ${_THL_PS_DM[@]+"${_THL_PS_DM[@]}"}; prc0a=(${THL_PRC_ALLOC[@]+"${THL_PRC_ALLOC[@]}"})
    for ((i = 0; i < n; i++)); do
        tok="${_THL_PS_TK[i]}"; prc="${prca[i]:-0}"; prc0="${prc0a[i]:-0}"
        _thl_alloc_count "$tok"; ht="$_THL_AC"
        row=0
        if _thl_sample_row "$tok"; then row=1
        elif [ "$g1" = 1 ] && [ "$ht" -ge 1 ]; then _THL_SR_W="$ht"; _THL_SR_SS="$ht"; row=1; fi
        if [ "$row" = 1 ]; then
            w="$_THL_SR_W"; ss="$_THL_SR_SS"; nw="$w"
            # A CPU or memory limit (prc < prc0) lowers ssthresh; a cap fall by demand alone keeps it.
            if [ "$prc" -lt "$prc0" ] && { [ "$w" -gt "$prc" ] || [ "$prc" -lt "${_THL_SR_CAP:-$prc}" ]; }; then
                ss="$prc"; [ "$ss" -ge 2 ] || ss=2
            fi
            if [ "$w" -gt "$prc" ]; then
                nw="$prc"
            elif _thl_alloc_may_grow "$grow_ok" "$cap" "$w" "$prc" "$ht"; then
                if [ "$w" -lt "$ss" ]; then nw=$((2 * w)); [ "$nw" -ge 1 ] || nw=1; [ "$nw" -le "$ss" ] || nw="$ss"
                else nw=$((w + 1)); fi
                [ "$nw" -le "$prc" ] || nw="$prc"
            fi
        else
            # A new run takes free host lanes in presence order, never fewer than it holds.
            nw="$THL_SLOW_START_INIT"
            [ "$nw" -le $((ht + free)) ] || nw=$((ht + free))
            [ "$nw" -ge "$ht" ] || nw="$ht"
            [ "$nw" -le "$prc" ] || nw="$prc"
            [ "$nw" -le "$ht" ] || free=$((free - (nw - ht)))
            ss="$top"
        fi
        if [ "$nw" -lt "$prc" ]; then
            db=slow-start; [ "$row" = 1 ] && [ "$cap" != none ] && db=memory-limit
        elif [ "$prc" -lt "$prc0" ]; then
            db=cpu-load-limit; [ "$cap" != none ] && [ "$cap" -le "$cpupool" ] && db=memory-limit
        else db='per-run-cap'; fi
        rows="$rows$tok $nw $ss $prc $db"$'\n'
    done
    _thl_now
    _THL_S_VALID=1; _THL_S_AT="$THL_NOW"; _THL_S_STATE="$_THL_M_STATE"; _THL_S_COUNTER="$_THL_M_COUNTER"
    _THL_S_HOSTBUSY="$_THL_M_HOSTBUSY"; _THL_S_EXT="$_THL_M_EXT"; _THL_S_RESERVED="$reserved"
    _THL_S_SCALE="$_THL_LS_SCALE"; _THL_S_ABOVE="$_THL_LS_ABOVE"; _THL_S_BELOW="$_THL_LS_BELOW"
    _THL_S_MEM_AVAIL="$av"; _THL_S_MEM_TOTAL="$tt"; _THL_S_MEM_RESERVE="$rs"; _THL_S_MEM_SCOPE="$sc"
    _THL_S_MEM_TESTS="$_THL_M_TESTS"; _THL_S_MEM_CAP="$cap"
    _THL_S_POOL="$pool"; _THL_S_RUNS="$n"; _THL_S_ROWS="$rows"
    return 0
}

# _thl_alloc_may_grow <grow-ok> <cap> <w> <per-run-cap> <held> — 0 when a row may grow: the
# sample is measured, no scale-in and no memory cap, below its cap, a free lane, its lanes used up.
_thl_alloc_may_grow() {
    [ "$1" = 1 ] && [ "$_THL_LS_SCALE" -eq 0 ] && [ "$2" = none ] || return 1
    [ "$3" -lt "$4" ] && [ "$_THL_AH_FREE" -gt 0 ] && [ "$5" -ge "$3" ]
}
