#!/usr/bin/env bash
# The run-all lane allocation sample load/sample, schema 2 (#2692): one header of 18 keys and one
# `alloc.<token>=<w> <ss> <cap> <decided_by>` row per run-all (<cap> = its run-all per-run lane
# cap). A strict, non-evaluating reader and an atomic writer over the _THL_S_* globals.
# Sourced by test-host-lanes.sh only.
# shellcheck disable=SC2034  # the _THL_S_* globals are read by the load, alloc and status libs

_THL_S_VALID=0

# _thl_sample_reset — every _THL_S_* global back to "no sample".
_thl_sample_reset() {
    _THL_S_VALID=0; _THL_S_AT=""; _THL_S_STATE=""; _THL_S_COUNTER=""; _THL_S_HOSTBUSY=0; _THL_S_EXT=0
    _THL_S_RESERVED=0; _THL_S_SCALE=0; _THL_S_ABOVE=0; _THL_S_BELOW=0
    _THL_S_MEM_AVAIL=unknown; _THL_S_MEM_TOTAL=unknown; _THL_S_MEM_RESERVE=unknown; _THL_S_MEM_SCOPE=unknown
    _THL_S_MEM_TESTS=0; _THL_S_MEM_CAP=none; _THL_S_POOL=0; _THL_S_RUNS=0; _THL_S_ROWS=""
}
_thl_sample_reset

# _thl_sample_val <key> <value> — 0 when <value> is well-formed for <key>; sets the global.
_thl_sample_val() {
    local v="$2" n='^[0-9]{1,9}$' s='^[0-9]{1,4}$' m='^([0-9]{1,9}|unknown)$' c='^([0-9]{1,9}|none)$'
    case "$1" in
        schema) [ "$v" = 2 ] ;;
        measured_at) [[ $v =~ ^[0-9]{1,12}$ ]] && _THL_S_AT="$v" ;;
        state) case "$v" in ok|unmeasurable|off) _THL_S_STATE="$v" ;; *) return 1 ;; esac ;;
        host_counter) case "$v" in node|'') _THL_S_COUNTER="$v" ;; *) return 1 ;; esac ;;
        host_busy_centicores) [[ $v =~ $n ]] && _THL_S_HOSTBUSY="$((10#$v))" ;;
        external_centicores) [[ $v =~ $n ]] && _THL_S_EXT="$((10#$v))" ;;
        reserved_cores) [[ $v =~ $n ]] && _THL_S_RESERVED="$((10#$v))" ;;
        scale_in) [[ $v =~ $s ]] && _THL_S_SCALE="$((10#$v))" ;;
        above) [[ $v =~ $s ]] && _THL_S_ABOVE="$((10#$v))" ;;
        below) [[ $v =~ $s ]] && _THL_S_BELOW="$((10#$v))" ;;
        mem_avail_mb) [[ $v =~ $m ]] && _THL_S_MEM_AVAIL="$v" ;;
        mem_total_mb) [[ $v =~ $m ]] && _THL_S_MEM_TOTAL="$v" ;;
        mem_reserve_mb) [[ $v =~ $m ]] && _THL_S_MEM_RESERVE="$v" ;;
        mem_scope) case "$v" in host|cgroup|unknown) _THL_S_MEM_SCOPE="$v" ;; *) return 1 ;; esac ;;
        mem_tests_mb) [[ $v =~ $n ]] && _THL_S_MEM_TESTS="$((10#$v))" ;;
        mem_cap) [[ $v =~ $c ]] && _THL_S_MEM_CAP="$v" ;;
        pool) [[ $v =~ $n ]] && _THL_S_POOL="$((10#$v))" ;;
        runs) [[ $v =~ $n ]] && _THL_S_RUNS="$((10#$v))" ;;
        *) return 1 ;;
    esac
}

# _thl_sample_read <file> — 0 only when every header key is present once and well-formed and
# the rows are unique, well-formed and as many as runs=. Never evaluates a value.
_thl_sample_read() {
    _thl_sample_read_1 "$1" && return 0
    _thl_sample_reset
    return 1
}
_thl_sample_read_1() {
    local line k v seen=" " n=0 rows=0 tok
    _thl_sample_reset
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        [ "$k" != "$line" ] || return 1
        case "$seen" in *" $k "*) return 1 ;; esac
        seen="$seen$k "
        if [ "${k#alloc.}" != "$k" ]; then
            tok="${k#alloc.}"
            [[ $tok =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
            [[ $v =~ ^[0-9]{1,4}\ [0-9]{1,4}\ [0-9]{1,4}\ (per-run-cap|cpu-load-limit|memory-limit|slow-start)$ ]] || return 1
            rows=$((rows + 1))
            [ "$rows" -le 256 ] || return 1
            _THL_S_ROWS="$_THL_S_ROWS$tok $v"$'\n'
            continue
        fi
        _thl_sample_val "$k" "$v" || return 1
        n=$((n + 1))
    done 2>/dev/null < "$1"
    [ "$n" -eq 18 ] && [ "$rows" -eq "$_THL_S_RUNS" ] || return 1
    _THL_S_VALID=1
}

# _thl_sample_gen1 <file> — 0 when <file> is a generation-1 sample (code that predates #2692 wrote it).
_thl_sample_gen1() {
    local line
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = schema=1 ] && return 0
    done 2>/dev/null < "$1"
    return 1
}

# _thl_sample_write <file> — the _THL_S_* globals as a sample, through a temp file and mv.
_thl_sample_write() {
    local t="$1.new.$$.$RANDOM" r tok w ss cap db
    {
        printf 'schema=2\nmeasured_at=%s\nstate=%s\nhost_counter=%s\nhost_busy_centicores=%s\n' \
            "$_THL_S_AT" "$_THL_S_STATE" "$_THL_S_COUNTER" "$_THL_S_HOSTBUSY"
        printf 'external_centicores=%s\nreserved_cores=%s\nscale_in=%s\nabove=%s\nbelow=%s\n' \
            "$_THL_S_EXT" "$_THL_S_RESERVED" "$_THL_S_SCALE" "$_THL_S_ABOVE" "$_THL_S_BELOW"
        printf 'mem_avail_mb=%s\nmem_total_mb=%s\nmem_reserve_mb=%s\nmem_scope=%s\nmem_tests_mb=%s\n' \
            "$_THL_S_MEM_AVAIL" "$_THL_S_MEM_TOTAL" "$_THL_S_MEM_RESERVE" "$_THL_S_MEM_SCOPE" "$_THL_S_MEM_TESTS"
        printf 'mem_cap=%s\npool=%s\nruns=%s\n' "$_THL_S_MEM_CAP" "$_THL_S_POOL" "$_THL_S_RUNS"
        while read -r tok w ss cap db; do
            [ -z "$tok" ] || printf 'alloc.%s=%s %s %s %s\n' "$tok" "$w" "$ss" "$cap" "$db"
        done <<< "$_THL_S_ROWS"
    } > "$t" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
    r=0
    mv -f "$t" "$1" 2>/dev/null || { rm -f "$t" 2>/dev/null; r=1; }
    return "$r"
}

# _thl_sample_row <token> — _THL_SR_W/SS/CAP/BY of that token's row; 1 when it has none.
_thl_sample_row() {
    local tok w ss cap db
    _THL_SR_W=""; _THL_SR_SS=""; _THL_SR_CAP=""; _THL_SR_BY=""
    while read -r tok w ss cap db; do
        [ "$tok" = "$1" ] || continue
        _THL_SR_W="$((10#$w))"; _THL_SR_SS="$((10#$ss))"; _THL_SR_CAP="$((10#$cap))"; _THL_SR_BY="$db"
        return 0
    done <<< "$_THL_S_ROWS"
    return 1
}

# _thl_sample_fresh <period> — _THL_S_AGE (seconds since measured_at); 0 when the read sample
# is at most three periods old.
_thl_sample_fresh() {
    _thl_now
    _THL_S_AGE=-1
    [ "$_THL_S_VALID" = 1 ] || return 1
    _THL_S_AGE=$((THL_NOW - 10#$_THL_S_AT))
    [ "$_THL_S_AGE" -ge 0 ] && [ "$_THL_S_AGE" -le $((3 * $1)) ]
}
