#!/usr/bin/env bash
# Load scale-in (#2687): the external CPU load (host busy time minus the own tests' CPU time)
# shrinks the run-all lane pool. One heartbeat per host measures (load/.claim) into
# load/sample; every run reads it with thl_load_scale_in. Sourced by test-host-lanes.sh only.

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

# _thl_load_read <file> — non-evaluating reader of load/sample: 0 only when every key is
# known, present once and well-formed. Sets _THL_LS_AT/STATE/SCALE/ABOVE/BELOW.
_thl_load_read() {
    local line k v seen=" " n=0
    _THL_LS_AT=""; _THL_LS_STATE=""; _THL_LS_SCALE=0; _THL_LS_ABOVE=0; _THL_LS_BELOW=0
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        k="${line%%=*}"; v="${line#*=}"
        [ "$k" != "$line" ] || return 1
        case "$seen" in *" $k "*) return 1 ;; esac
        seen="$seen$k "
        case "$k" in
            schema) [ "$v" = 1 ] || return 1 ;;
            measured_at) [[ $v =~ ^[0-9]{1,12}$ ]] || return 1; _THL_LS_AT="$v" ;;
            state) case "$v" in ok|unmeasurable) _THL_LS_STATE="$v" ;; *) return 1 ;; esac ;;
            host_counter) case "$v" in system|process-sum|'') ;; *) return 1 ;; esac ;;
            external_centicores) [[ $v =~ ^[0-9]{1,9}$ ]] || return 1 ;;
            scale_in) [[ $v =~ ^[0-9]{1,4}$ ]] || return 1; _THL_LS_SCALE="$((10#$v))" ;;
            above) [[ $v =~ ^[0-9]{1,4}$ ]] || return 1; _THL_LS_ABOVE="$((10#$v))" ;;
            below) [[ $v =~ ^[0-9]{1,4}$ ]] || return 1; _THL_LS_BELOW="$((10#$v))" ;;
            *) return 1 ;;
        esac
        n=$((n + 1))
    done 2>/dev/null < "$1"
    [ "$n" -eq 8 ]
}

# thl_load_scale_in — THL_LOAD_SCALE_IN from a valid, measured sample at most three
# heartbeats old; 0 in mode off and on any doubt.
thl_load_scale_in() {
    THL_LOAD_SCALE_IN=0
    _thl_load_on || return 0
    _thl_load_read "$THL_CACHE_ROOT/load/sample" || return 0
    [ "$_THL_LS_STATE" = ok ] || return 0
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    _thl_now
    local age=$((THL_NOW - 10#$_THL_LS_AT))
    [ "$age" -ge 0 ] && [ "$age" -le $((3 * _THL_INT)) ] || return 0
    # shellcheck disable=SC2034  # read by the fair-share pool in test-host-lanes-share.sh
    THL_LOAD_SCALE_IN="$_THL_LS_SCALE"
    return 0
}

# _thl_load_hysteresis <state> <external-centicores> — move _THL_LS_SCALE/ABOVE/BELOW:
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

# _thl_load_compute <prev> <cur> <roots> — state=, host_counter=, external_centicores= and,
# when unmeasurable, reason=. Own CPU = the roots and their descendants (by ppid).
_thl_load_compute() {
    run_all_logical_cpu_count
    awk -v P="$1" -v C="$2" -v R="$3" -v ncpu="${RUN_ALL_LOGICAL_CPU_COUNT:-0}" '
        function bad(why) { printf "state=unmeasurable\nhost_counter=\nexternal_centicores=0\nreason=%s\n", why; exit 0 }
        function load(f, pre,   line, n, k, v, a) {
            n = 0
            while ((getline line < f) > 0) {
                n++
                if (n == 1) { if (line !~ /^wall_ms=[0-9]+$/) bad("snapshot"); H[pre "wall"] = substr(line, 9) + 0; continue }
                if (line ~ /^host_[a-z0-9_]+=/) {
                    k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v)
                    if (v == "unavailable" && k == "host_busy_ms") continue
                    if (v !~ /^[0-9]+$/) bad("snapshot")
                    H[pre k] = v + 0; continue
                }
                if (line !~ /^[0-9]+ [0-9]+ [0-9]+$/) bad("snapshot")
                split(line, a, " ")
                if (pre == "c") { CP[a[1]] = a[3] + 0; PP[a[1]] = a[2] } else PV[a[1]] = a[3] + 0
            }
            close(f)
            if (n == 0) bad("snapshot")
        }
        BEGIN {
            load(P, "p"); load(C, "c")
            dw = H["cwall"] - H["pwall"]
            if (dw <= 0) bad("wall")
            for (pid in CP) { if (pid == 0) continue; d = CP[pid] - ((pid in PV) ? PV[pid] : 0); if (d < 0) d = 0; D[pid] = d }
            nr = 0
            while ((getline line < R) > 0) if (line ~ /^[0-9]+$/ && (line in CP)) { OWN[line] = 1; nr++ }
            close(R)
            if (nr == 0) bad("roots")
            do { grew = 0; for (pid in CP) if (!(pid in OWN) && (PP[pid] in OWN) && pid != PP[pid]) { OWN[pid] = 1; grew = 1 } } while (grew)
            own = 0; sum = 0
            for (pid in D) { sum += D[pid]; if (pid in OWN) own += D[pid] }
            counter = "process-sum"; host = sum
            if (("phost_busy_ms" in H) && ("chost_busy_ms" in H)) {
                counter = "system"; host = H["chost_busy_ms"] - H["phost_busy_ms"]
            } else if (("phost_idle_100ns" in H) && ("phost_ts_100ns" in H) && ("phost_cpus" in H) &&
                       ("chost_idle_100ns" in H) && ("chost_ts_100ns" in H) && ("chost_cpus" in H)) {
                counter = "system"
                host = ((H["chost_ts_100ns"] - H["phost_ts_100ns"]) * H["chost_cpus"] - (H["chost_idle_100ns"] - H["phost_idle_100ns"])) / 10000
            }
            if (counter == "system" && host < 0) bad("host-counter")
            if (ncpu > 0 && host > ncpu * dw) host = ncpu * dw
            ext = host - own
            if (ext < 0) ext = 0
            printf "state=ok\nhost_counter=%s\nexternal_centicores=%d\n", counter, ext * 100 / dw
        }'
}

# _thl_load_claim <dir> <period> — 0 when this process now holds <dir>/.claim; a claim
# older than three heartbeats is reclaimed through a grave.
_thl_load_claim() {
    local c="$1/.claim" m g
    mkdir "$c" 2>/dev/null && return 0
    m="$(stat -c %Y "$c" 2>/dev/null || stat -f %m "$c" 2>/dev/null)"
    [[ $m =~ ^[0-9]+$ ]] || return 1
    _thl_now
    [ $((THL_NOW - m)) -ge $((3 * $2)) ] || return 1
    g="$1/.grave.claim.$$.$RANDOM"
    mv "$c" "$g" 2>/dev/null || return 1
    rm -rf "$g" 2>/dev/null
    mkdir "$c" 2>/dev/null
}

# thl_load_tick — one sampler step: when the sample is due and the claim is free, take a
# snapshot, compute against the previous one, run the hysteresis, write load/sample.
thl_load_tick() {
    _thl_load_on || return 0
    local dir="$THL_CACHE_ROOT/load" period age fresh=0 state=unmeasurable counter="" ext=0 new out roots line
    _thl_int "${TEST_LANES_HEARTBEAT:-}" "$THL_HEARTBEAT_DEFAULT"
    period="$_THL_INT"
    _thl_now
    if _thl_load_read "$dir/sample"; then
        age=$((THL_NOW - 10#$_THL_LS_AT))
        [ "$age" -ge 0 ] && [ "$age" -lt "$period" ] && return 0
        [ "$age" -ge 0 ] && [ "$age" -le $((3 * period)) ] && fresh=1
    fi
    [ "$fresh" -eq 1 ] || { _THL_LS_SCALE=0; _THL_LS_ABOVE=0; _THL_LS_BELOW=0; }
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    _thl_load_claim "$dir" "$period" || return 0
    new="$dir/snapshot.new.$$.$RANDOM"
    if _thl_load_snapshot "$new"; then
        if [ "$fresh" -eq 1 ] && [ -s "$dir/snapshot" ]; then
            roots="$dir/roots.$$.$RANDOM"
            _thl_load_roots > "$roots" 2>/dev/null
            out="$(_thl_load_compute "$dir/snapshot" "$new" "$roots" 2>/dev/null)"
            rm -f "$roots"
            while IFS= read -r line; do
                case "$line" in
                    state=ok) state=ok ;;
                    host_counter=*) counter="${line#host_counter=}" ;;
                    external_centicores=*) ext="${line#external_centicores=}" ;;
                esac
            done <<< "$out"
            [[ $ext =~ ^[0-9]{1,9}$ ]] || { state=unmeasurable; ext=0; }
            case "$counter" in system|process-sum) ;; *) counter="" ;; esac
        fi
        mv -f "$new" "$dir/snapshot" 2>/dev/null
    fi
    rm -f "$new" 2>/dev/null
    [ "$state" = ok ] || { counter=""; ext=0; }
    _thl_load_hysteresis "$state" "$ext"
    _thl_now
    out="$dir/sample.new.$$.$RANDOM"
    { printf 'schema=1\nmeasured_at=%s\nstate=%s\nhost_counter=%s\nexternal_centicores=%s\nscale_in=%s\nabove=%s\nbelow=%s\n' \
        "$THL_NOW" "$state" "$counter" "$ext" "$_THL_LS_SCALE" "$_THL_LS_ABOVE" "$_THL_LS_BELOW" > "$out"; } 2>/dev/null
    mv -f "$out" "$dir/sample" 2>/dev/null || rm -f "$out" 2>/dev/null
    rmdir "$dir/.claim" 2>/dev/null
    return 0
}
