#!/usr/bin/env bash
# Load sampler (#2687, #2692): one heartbeat per host (load/.claim) measures the external CPU
# load and the memory into load/sample, then the alloc lib writes every run's row. Every run
# reads the sample (thl_load_scale_in, the share lib). Sourced by test-host-lanes.sh only.
# shellcheck disable=SC2153  # the _THL_S_* globals are set by test-host-load-sample.sh

THL_LOAD_ENGAGE_CENTICORES=100
THL_LOAD_RELEASE_CENTICORES=50
THL_LOAD_ENGAGE_SAMPLES=2
THL_LOAD_RELEASE_SAMPLES=3
THL_LOAD_SCALE_IN=0
_THL_LOAD_MODE=""

# _thl_load_on — 0 when automatic configuration is on (resolved once per process).
_thl_load_on() {
    if [ -z "$_THL_LOAD_MODE" ]; then
        run_all_auto_config 2>/dev/null
        _THL_LOAD_MODE="$RUN_ALL_AUTO_CONFIG"
    fi
    [ "$_THL_LOAD_MODE" = on ]
}

# thl_load_scale_in — THL_LOAD_SCALE_IN from a valid, measured sample at most three
# heartbeats old; 0 in mode off and on any doubt.
thl_load_scale_in() {
    THL_LOAD_SCALE_IN=0
    _thl_load_on || return 0
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    _thl_sample_read "$THL_CACHE_ROOT/load/sample" || return 0
    [ "$_THL_S_STATE" = ok ] || return 0
    _thl_sample_fresh "$_THL_INT" || return 0
    # shellcheck disable=SC2034  # read by callers of the reader
    THL_LOAD_SCALE_IN="$_THL_S_SCALE"
    return 0
}

# _thl_load_hysteresis <state> <excess-centicores> — move _THL_LS_SCALE/ABOVE/BELOW:
# engage after 2 samples >= 100 (scale = whole cores), release after 3 samples < 50.
_thl_load_hysteresis() {
    local ext="$2"
    if [ "$1" != ok ]; then _THL_LS_SCALE=0; _THL_LS_ABOVE=0; _THL_LS_BELOW=0; return 0; fi
    if [ "$ext" -ge "$THL_LOAD_ENGAGE_CENTICORES" ]; then
        _THL_LS_ABOVE=$((_THL_LS_ABOVE + 1)); _THL_LS_BELOW=0
        if [ "$_THL_LS_SCALE" -gt 0 ] || [ "$_THL_LS_ABOVE" -ge "$THL_LOAD_ENGAGE_SAMPLES" ]; then
            _THL_LS_SCALE=$((ext / 100))
        fi
    elif [ "$ext" -lt "$THL_LOAD_RELEASE_CENTICORES" ]; then
        _THL_LS_BELOW=$((_THL_LS_BELOW + 1)); _THL_LS_ABOVE=0
        [ "$_THL_LS_SCALE" -gt 0 ] && [ "$_THL_LS_BELOW" -ge "$THL_LOAD_RELEASE_SAMPLES" ] && _THL_LS_SCALE=0
    else
        _THL_LS_ABOVE=0; _THL_LS_BELOW=0
    fi
    [ "$_THL_LS_ABOVE" -le 9999 ] || _THL_LS_ABOVE=9999
    [ "$_THL_LS_BELOW" -le 9999 ] || _THL_LS_BELOW=9999
    return 0
}

# _thl_load_roots — the pids (Windows pids where /proc/<pid>/winpid exists) of the live
# same-environment owners of lanes and presence records, one per line, deduplicated.
_thl_load_roots() {
    local d p w seen=" "
    for d in "$THL_CACHE_ROOT"/slots/lane.* "$THL_CACHE_ROOT"/runs/run.*; do
        [ -d "$d" ] || continue
        _thl_read_owner "$d" || continue
        [ "$_THL_O_ENV" = "${OSTYPE:-}" ] || continue
        kill -0 "$_THL_O_PID" 2>/dev/null || continue
        p="$_THL_O_PID"
        if [ -r "/proc/$p/winpid" ]; then
            w=""
            { IFS= read -r w < "/proc/$p/winpid"; } 2>/dev/null
            [[ $w =~ ^[0-9]+$ ]] && p="$w"
        fi
        case "$seen" in *" $p "*) continue ;; esac
        seen="$seen$p "
        printf '%s\n' "$p"
    done
    return 0
}

# _thl_load_compute <prev> <cur> <roots> — the measurement as key=value lines (reason= when
# unmeasurable). External = the CPU deltas of every process outside the internal set (the
# roots, `claude` processes and their descendants), capped by the CPUs; the host counter is
# only a sanity check and the display value.
_thl_load_compute() {
    run_all_logical_cpu_count
    awk -v P="$1" -v C="$2" -v R="$3" -v ncpu="${RUN_ALL_LOGICAL_CPU_COUNT:-0}" '
        function bad(why) {
            printf "state=unmeasurable\nhost_counter=\nhost_busy_centicores=0\nexternal_centicores=0\n"
            printf "mem_avail_mb=unknown\nmem_total_mb=unknown\nmem_scope=unknown\nmem_tests_mb=0\nreason=%s\n", why
            exit 0
        }
        function load(f, pre,   line, n, k, v, a, snap) {
            n = 0; snap = 0
            while ((getline line < f) > 0) {
                n++
                if (n == 1) { if (line !~ /^wall_ms=[0-9]+$/) bad("snapshot"); H[pre "wall"] = substr(line, 9) + 0; continue }
                if (line == "snapshot=2") { snap = 1; continue }
                if (line ~ /^host_/) {
                    k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v)
                    if (k == "host_mem_scope") { if (v != "host" && v != "cgroup") bad("snapshot"); H[pre k] = v; continue }
                    if (k != "host_busy_ms" && k != "host_cpus" && k != "host_mem_avail_kb" && k != "host_mem_total_kb") bad("snapshot")
                    if (v !~ /^[0-9]+$/) bad("snapshot")
                    H[pre k] = v + 0; continue
                }
                if (split(line, a, " ") != 5 || a[1] !~ /^[0-9]+$/ || a[2] !~ /^[0-9]+$/ || a[3] !~ /^[0-9]+$/ || a[4] !~ /^[0-9]+$/) bad("snapshot")
                if (pre == "c") { CP[a[1]] = a[3] + 0; PP[a[1]] = a[2]; RSK[a[1]] = a[4] + 0; NM[a[1]] = a[5] } else PV[a[1]] = a[3] + 0
            }
            close(f)
            if (n == 0 || !snap) bad("snapshot")
        }
        function closure(S,   pid, g) {
            do { g = 0; for (pid in CP) if (!(pid in S) && (PP[pid] in S) && pid != PP[pid]) { S[pid] = 1; g = 1 } } while (g)
        }
        BEGIN {
            load(P, "p"); load(C, "c")
            dw = H["cwall"] - H["pwall"]
            if (dw <= 0) bad("wall")
            nr = 0
            while ((getline line < R) > 0) if (line ~ /^[0-9]+$/ && (line in CP)) { TA[line] = 1; nr++ }
            close(R)
            if (nr == 0) bad("roots")
            closure(TA)
            tests = 0
            for (pid in TA) { tests += RSK[pid]; IN[pid] = 1 }
            for (pid in CP) { nm = tolower(NM[pid]); sub(/\.exe$/, "", nm); if (nm == "claude") IN[pid] = 1 }
            closure(IN)
            ext = 0
            for (pid in CP) {
                if (pid == "0" || (pid in IN)) continue
                d = CP[pid] - ((pid in PV) ? PV[pid] : 0)
                if (d > 0) ext += d
            }
            if (ncpu > 0 && ext > ncpu * dw) ext = ncpu * dw
            counter = ""; hb = 0
            if (("phost_busy_ms" in H) && ("chost_busy_ms" in H)) {
                host = H["chost_busy_ms"] - H["phost_busy_ms"]
                if (host < 0) bad("host-counter")
                counter = "node"; hb = int(host * 100 / dw)
            }
            av = "unknown"; tt = "unknown"; sc = "unknown"
            if ("chost_mem_avail_kb" in H) av = sprintf("%d", int(H["chost_mem_avail_kb"] / 1024))
            if (("chost_mem_total_kb" in H) && ("chost_mem_scope" in H)) { tt = sprintf("%d", int(H["chost_mem_total_kb"] / 1024)); sc = H["chost_mem_scope"] }
            printf "state=ok\nhost_counter=%s\nhost_busy_centicores=%d\nexternal_centicores=%d\n", counter, hb, int(ext * 100 / dw)
            printf "mem_avail_mb=%s\nmem_total_mb=%s\nmem_scope=%s\nmem_tests_mb=%d\n", av, tt, sc, int(tests / 1024)
        }'
}

# _thl_load_claim <dir> <period> — 0 when this process now holds <dir>/.claim, marked with the
# owner token _THL_CLAIM_TOKEN and the holder's heartbeat (.claim/heartbeat); a claim older than
# three recorded heartbeats (<period> when none is validly recorded) is reclaimed through a grave.
_thl_load_claim() {
    local c="$1/.claim" m g p=""
    _THL_CLAIM_TOKEN="$$.$RANDOM.$RANDOM"
    if ! mkdir "$c" 2>/dev/null; then
        m="$(stat -c %Y "$c" 2>/dev/null || stat -f %m "$c" 2>/dev/null)"
        [[ $m =~ ^[0-9]+$ ]] || return 1
        { IFS= read -r p < "$c/heartbeat"; } 2>/dev/null
        [[ $p =~ ^[1-9][0-9]{0,8}$ ]] || p="$2"
        _thl_now
        [ $((THL_NOW - m)) -ge $((3 * p)) ] || return 1
        g="$1/.grave.claim.$$.$RANDOM"
        mv "$c" "$g" 2>/dev/null || return 1
        rm -rf "$g" 2>/dev/null
        mkdir "$c" 2>/dev/null || return 1
    fi
    { printf '%s\n' "$_THL_CLAIM_TOKEN" > "$c/owner"; } 2>/dev/null
    { printf '%s\n' "$2" > "$c/heartbeat"; } 2>/dev/null
    return 0
}

# _thl_load_holds <dir> — 0 while <dir>/.claim still carries this process's owner token (a slow
# holder reclaimed through the grave no longer does).
_thl_load_holds() {
    local t=""
    { IFS= read -r t < "$1/.claim/owner"; } 2>/dev/null
    [ -n "$t" ] && [ "$t" = "${_THL_CLAIM_TOKEN:-}" ]
}

# _thl_load_measure <dir> <prev-fresh> — _THL_M_*: state off in mode off (no probe); else a
# snapshot kept as snapshot.2 and, with a fresh previous sample and snapshot, the computation.
_thl_load_measure() {
    local dir="$1" new roots out line k v st=unmeasurable co="" hb=0 ex=0 av=unknown tt=unknown sc=unknown ts=0
    local n='^[0-9]{1,9}$' m='^([0-9]{1,9}|unknown)$'
    _THL_M_STATE=unmeasurable; _THL_M_COUNTER=""; _THL_M_HOSTBUSY=0; _THL_M_EXT=0
    _THL_M_AVAIL=unknown; _THL_M_TOTAL=unknown; _THL_M_SCOPE=unknown; _THL_M_TESTS=0
    if ! _thl_load_on; then _THL_M_STATE=off; return 0; fi
    new="$dir/snapshot.new.$$.$RANDOM"
    if ! _thl_load_snapshot "$new"; then rm -f "$new" 2>/dev/null; return 0; fi
    if [ "$2" = 1 ] && [ -s "$dir/snapshot.2" ]; then
        roots="$dir/roots.$$.$RANDOM"
        _thl_load_roots > "$roots" 2>/dev/null
        out="$(_thl_load_compute "$dir/snapshot.2" "$new" "$roots" 2>/dev/null)"
        rm -f "$roots" 2>/dev/null
        while IFS= read -r line; do
            k="${line%%=*}"; v="${line#*=}"
            case "$k" in
                state) st="$v" ;; host_counter) co="$v" ;; host_busy_centicores) hb="$v" ;;
                external_centicores) ex="$v" ;; mem_avail_mb) av="$v" ;; mem_total_mb) tt="$v" ;;
                mem_scope) sc="$v" ;; mem_tests_mb) ts="$v" ;;
            esac
        done <<< "$out"
        if [ "$st" = ok ] && [[ $hb =~ $n && $ex =~ $n && $ts =~ $n && $av =~ $m && $tt =~ $m ]]; then
            case "$co:$sc" in
                node:host|node:cgroup|node:unknown|:host|:cgroup|:unknown)
                    _THL_M_STATE=ok; _THL_M_COUNTER="$co"; _THL_M_HOSTBUSY="$((10#$hb))"; _THL_M_EXT="$((10#$ex))"
                    _THL_M_AVAIL="$av"; _THL_M_TOTAL="$tt"; _THL_M_SCOPE="$sc"; _THL_M_TESTS="$((10#$ts))" ;;
            esac
        fi
    fi
    mv -f "$new" "$dir/snapshot.2" 2>/dev/null || rm -f "$new" 2>/dev/null
    return 0
}

# thl_load_tick — one sampler step in either mode: when the run-all lane allocation sample is due
# and the claim is free, measure, run the allocation (_thl_alloc_run) and write load/sample; the
# write and the release happen only while the claim is still this run's and at most two heartbeats old.
thl_load_tick() {
    local dir="$THL_CACHE_ROOT/load" period claimed
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    period="$_THL_INT"
    _thl_load_tick_read "$dir" "$period" || return 0
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    _thl_load_claim "$dir" "$period" || return 0
    # Another holder may have written the sample between the read and the claim (#2692).
    if ! _thl_load_tick_read "$dir" "$period"; then
        _thl_load_holds "$dir" && _thl_load_release "$dir"
        return 0
    fi
    _thl_now
    claimed="$THL_NOW"
    _thl_load_measure "$dir" "$_THL_TR_PREVFRESH"
    _thl_alloc_run "$_THL_TR_PREVFRESH" "$_THL_TR_GEN1"
    # Past two heartbeats the tick is void: the grave reclaim waits three, so it never overlaps the next holder.
    _thl_now
    [ $((THL_NOW - claimed)) -le $((2 * period)) ] || return 0
    _thl_load_holds "$dir" || return 0
    _thl_sample_write "$dir/sample"
    _thl_now
    [ $((THL_NOW - claimed)) -le $((2 * period)) ] || return 0
    _thl_load_holds "$dir" || return 0
    _thl_load_release "$dir"
    return 0
}

# _thl_load_tick_read <dir> <period> — 1 when <dir>/sample is under one heartbeat old (nothing
# due); else 0 with _THL_TR_PREVFRESH, _THL_TR_GEN1 and the _THL_S_* globals of the read.
_thl_load_tick_read() {
    local age rows
    _THL_TR_PREVFRESH=0; _THL_TR_GEN1=0
    if _thl_sample_read "$1/sample"; then
        _thl_now
        age=$((THL_NOW - 10#$_THL_S_AT))
        [ "$age" -ge 0 ] && [ "$age" -lt "$2" ] && return 1
        _thl_sample_fresh "$2" && _THL_TR_PREVFRESH=1
    elif _thl_sample_gen1 "$1/sample"; then
        _THL_TR_GEN1=1
    fi
    # A stale sample drops its header but keeps its rows: each run keeps its width (#2692).
    if [ "$_THL_TR_PREVFRESH" -ne 1 ]; then rows="$_THL_S_ROWS"; _thl_sample_reset; _THL_S_ROWS="$rows"; fi
    return 0
}

# _thl_load_release <dir> — remove this holder's <dir>/.claim.
_thl_load_release() {
    rm -f "$1/.claim/heartbeat" "$1/.claim/owner" 2>/dev/null
    rmdir "$1/.claim" 2>/dev/null
    return 0
}
