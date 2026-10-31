# shellcheck shell=bash
# tests/lib/load-sample2-fixture.sh — sourced. File helpers for the #2692 load sample schema 2
# (bin/lib/test-host-load-sample.sh) and snapshot format 2; no lib is sourced here.

LS2_KEYS=(schema measured_at state host_counter host_busy_centicores external_centicores
    reserved_cores scale_in above below mem_avail_mb mem_total_mb mem_reserve_mb
    mem_scope mem_tests_mb mem_cap pool runs)

# ls2_write <cache> <age-s> [key=val ...] [-- <token>=<w> <ss> <fs> <decided_by> ...] — every
# header key (value DROP leaves it out), then the alloc rows; runs= defaults to the row count.
ls2_write() {
    local cache="$1" age="$2" k kv now
    shift 2
    local -A v=()
    local -a rows=()
    printf -v now '%(%s)T' -1
    v=([schema]=2 [measured_at]=$((now - age)) [state]=ok [host_counter]=node [host_busy_centicores]=0
        [external_centicores]=0 [reserved_cores]=0 [scale_in]=0 [above]=0 [below]=0
        [mem_avail_mb]=unknown [mem_total_mb]=unknown [mem_reserve_mb]=unknown [mem_scope]=unknown
        [mem_tests_mb]=0 [mem_cap]=none [pool]=15 [runs]=)
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do kv="$1"; v["${kv%%=*}"]="${kv#*=}"; shift; done
    [ "$#" -gt 0 ] && shift
    rows=("$@")
    [ -n "${v[runs]}" ] || v[runs]="${#rows[@]}"
    mkdir -p "$cache/load"
    {
        for k in "${LS2_KEYS[@]}"; do [ "${v[$k]}" = DROP ] || printf '%s=%s\n' "$k" "${v[$k]}"; done
        for kv in ${rows[@]+"${rows[@]}"}; do printf 'alloc.%s\n' "$kv"; done
    } > "$cache/load/sample.ls2.$$"
    mv -f "$cache/load/sample.ls2.$$" "$cache/load/sample"
}

# ls2_key <cache> <key> / ls2_row <cache> <token> — a header value / an alloc row, empty when absent.
ls2_key() { sed -n "s/^$2=//p" "$1/load/sample" 2>/dev/null | head -n 1; }
ls2_row() {
    local t="${2//./\\.}"
    sed -n "s/^alloc\.$t=//p" "$1/load/sample" 2>/dev/null | head -n 1
}

# ls2_snap <file> <wall_ms> <busy_ms|-> <root-pid> <ext_cpu_ms> [<avail_kb> <total_kb> <scope>]
# — one format-2 snapshot: the root (bash; rss LS2_ROOT_RSS_KB, default 10 MB) and one
# external process 7100.
ls2_snap() {
    {
        printf 'wall_ms=%s\nsnapshot=2\n' "$2"
        [ "$3" = - ] || printf 'host_busy_ms=%s\nhost_cpus=16\n' "$3"
        [ "$#" -ge 8 ] && printf 'host_mem_avail_kb=%s\nhost_mem_total_kb=%s\nhost_mem_scope=%s\n' "$6" "$7" "$8"
        printf '%s 1 500 %s bash\n7100 1 %s 4096 game.exe\n' "$4" "${LS2_ROOT_RSS_KB:-10240}" "$5"
    } > "$1"
}
