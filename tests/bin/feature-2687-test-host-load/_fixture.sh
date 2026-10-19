#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load/_fixture.sh — shared helpers: fixture snapshots, the
# probe stub behind TEST_LANES_LOAD_PROBE_CMD, sample files and the lib driver.
# Sourced FIRST by the dispatcher.

now_epoch() { printf '%(%s)T' -1; }

# The root pid as the load lib must see it: the Windows PID when /proc/<pid>/winpid exists.
ROOT_PID="$LIVE_SLEEP"
if [ -r "/proc/$LIVE_SLEEP/winpid" ]; then
    _w="$(cat "/proc/$LIVE_SLEEP/winpid" 2>/dev/null)"
    [[ $_w =~ ^[0-9]+$ ]] && ROOT_PID="$_w"
fi

# mk_slot <cache> <i> <pid> [env] — one lane held by <pid> (a root of the own tests).
mk_slot() {
    local d="$1/slots/lane.$2" hb
    hb="$(now_epoch)"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\n' "$3" "${4:-$OSTYPE}" "$hb" "$3.$hb.4242" > "$d/owner"
    printf '%s\n' "$hb" > "$d/hb"
}

# mk_presence <cache> <token> <pid> <start> [max-jobs-per-host] [demand] [env]
mk_presence() {
    local d="$1/runs/run.$2"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\nmax_jobs_per_run=%s\nmax_jobs_per_host=%s\n' \
        "$3" "${7:-$OSTYPE}" "$4" "$2" "${6:-1000}" "${5:-12}" > "$d/owner"
    now_epoch > "$d/hb"
}

# mk_sample <cache> <measured_at> <scale_in> [external_centicores] — a valid load/sample.
mk_sample() {
    mkdir -p "$1/load"
    printf 'schema=1\nmeasured_at=%s\nstate=ok\nhost_counter=system\nexternal_centicores=%s\nscale_in=%s\nabove=2\nbelow=0\n' \
        "$2" "${4:-$(($3 * 100))}" "$3" > "$1/load/sample"
}

# mk_record <cache> <max-jobs-per-host> — a valid schema-3 parallelism.conf for this host,
# so mode on never starts a calibration and the measured layer supplies max jobs per host.
mk_record() {
    local hid os
    hid="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB" 2>/dev/null)"
    os="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB" 2>/dev/null)"
    printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=%s\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=64\nmax_width_measured=64\nwidth_limit=logical-cpu-count\n' \
        "$hid" "$os" "$2" > "$1/parallelism.conf"
}

# gen_snaps <dir> <own0|ownheavy> <ext-centicores...> — snap.1 .. snap.<n+1>, 2000 ms apart,
# cumulative counters. Interval k adds <ext_k> centicores of external host busy time; under
# ownheavy the root's child and grandchild add 8 cores between them on top (host counts it too).
gen_snaps() {
    local dir="$1" mode="$2" k=1 wall=100000 busy=1000000 own=0 e
    shift 2
    mkdir -p "$dir"
    rm -f "$dir"/snap.* "$dir/count"
    _gen_one() {
        {
            printf 'wall_ms=%s\nhost_busy_ms=%s\n' "$wall" "$busy"
            printf '%s 1 500\n' "$ROOT_PID"
            printf '%s %s %s\n' 7001 "$ROOT_PID" "$own" 7002 7001 "$own"
            printf '7100 1 900\n'
        } > "$dir/snap.$k"
    }
    _gen_one
    for e in "$@"; do
        k=$((k + 1)); wall=$((wall + 2000)); busy=$((busy + e * 20))
        if [ "$mode" = ownheavy ]; then own=$((own + 8000)); busy=$((busy + 16000)); fi
        _gen_one
    done
}

# The probe stub: call n serves <LS_SNAP_DIR>/snap.<n>. Missing file or FAIL -> exit 1;
# SLEEP -> sleep 25, then serve snap.<n>.after (a valid snapshot: no timeout means measured).
PROBE_STUB="$TMPDIR_BASE/probe-stub.sh"
cat > "$PROBE_STUB" <<'STUB'
#!/usr/bin/env bash
d="${LS_SNAP_DIR:?}"
n=0; [ -f "$d/count" ] && n="$(cat "$d/count")"
n=$((n + 1)); printf '%s\n' "$n" > "$d/count"
f="$d/snap.$n"
[ -f "$f" ] || exit 1
case "$(head -n 1 "$f")" in
    FAIL) exit 1 ;;
    SLEEP) sleep 25; cat "$f.after"; exit 0 ;;
esac
cat "$f"
STUB
chmod +x "$PROBE_STUB"

# probe_calls <dir> — how many times the stub ran.
probe_calls() { if [ -f "$1/count" ]; then cat "$1/count"; else printf '0'; fi; }

cpu_shim() {
    mkdir -p "$1"
    printf '#!%s\nprintf "%%s\\n" %q\n' "$(type -P bash)" "$2" > "$1/nproc"
    chmod +x "$1/nproc"
}
CPU64="$TMPDIR_BASE/cpu-64"; cpu_shim "$CPU64" 64
CPU4="$TMPDIR_BASE/cpu-4"; cpu_shim "$CPU4" 4

# Driver-side helpers (run inside the driver, after thl_init_dir).
ls_key() { sed -n "s/^$1=//p" "$THL_CACHE_ROOT/load/sample" 2>/dev/null | head -n 1; }
ls_age() {
    local f="$THL_CACHE_ROOT/load/sample" t
    [ -f "$f" ] || return 0
    t=$(($(date +%s) - ${1:-3}))
    sed -i "s/^measured_at=.*/measured_at=$t/" "$f"
}
# ls_ticks <n> — n sampler ticks, the sample aged past one heartbeat (2s) before each later tick.
ls_ticks() {
    local i
    for ((i = 1; i <= $1; i++)); do
        [ "$i" -gt 1 ] && ls_age 3
        thl_load_tick
        printf 'tick%s state=%s ext=%s scale=%s\n' "$i" "$(ls_key state)" "$(ls_key external_centicores)" "$(ls_key scale_in)"
    done
}
DRV_HELPERS="$TMPDIR_BASE/load-drv-helpers.sh"
declare -f ls_key ls_age ls_ticks > "$DRV_HELPERS"

# The driver: both existing libs, then the load libs unless the lanes lib already loaded them.
LOAD_DRV="$TMPDIR_BASE/load-drv.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$DRV_PAR_LIB" 2>/dev/null || { echo "DRV: parallelism lib missing" >&2; exit 90; }' \
    '. "$DRV_LANES_LIB" 2>/dev/null || { echo "DRV: lanes lib missing" >&2; exit 91; }' \
    'if ! declare -F thl_load_tick >/dev/null 2>&1; then for f in "$DRV_PROBE_LIB" "$DRV_LOAD_LIB"; do [ -f "$f" ] && . "$f"; done; fi' \
    'declare -F thl_load_tick >/dev/null 2>&1 && declare -F _thl_load_compute >/dev/null 2>&1 || { echo "DRV: load lib not loaded (not implemented)" >&2; exit 93; }' \
    '. "$DRV_HELPERS"' 'thl_init_dir' \
    'eval "$1"' > "$LOAD_DRV"

OUT=""
ERR=""
RC=0
# load_drv <cache> <snap-dir> [NAME=VAL ...] -- <snippet> — sets OUT / ERR / RC.
# Defaults: mode on, heartbeat 2s, the probe stub, 64 logical CPUs.
load_drv() {
    local cache="$1" snaps="$2"; shift 2
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/drv.out" errf="$TMPDIR_BASE/drv.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 90 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" "DRV_LOAD_LIB=$LOAD_LIB" \
            "DRV_PROBE_LIB=$PROBE_LIB" "DRV_HELPERS=$DRV_HELPERS" "RUN_ALL_CACHE_DIR=$cache" "LS_SNAP_DIR=$snaps" \
            AUTO_CONFIG_TEST_MAX_JOBS=on TEST_LANES_HEARTBEAT=2 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 \
            "TEST_LANES_LOAD_PROBE_CMD=$PROBE_STUB" "PATH=$CPU64:$PATH" ${envs[@]+"${envs[@]}"} bash "$LOAD_DRV" "$1"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}

# kv_of <text> <key> — value of the first `key=value` line (also matches `tickN ... key=value`).
kv_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
# tick_field <text> <tickN> <field> — one field of one ls_ticks line.
tick_field() { printf '%s\n' "$1" | sed -n "s/^$2 .*$3=\([^ ]*\).*/\1/p" | head -n 1; }
# scales <text> — every tick's scale, space-joined.
scales() { printf '%s\n' "$1" | sed -n 's/^tick[0-9]* .*scale=\([^ ]*\).*/\1/p' | tr '\n' ' ' | sed 's/ *$//'; }

# near <got> <want> <tol> — 0 when |got-want| <= tol (got must be an integer).
near() {
    [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
    local d=$(($1 - $2))
    [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -le "$3" ]
}
assert_near() {
    if near "$3" "$2" "${4:-5}"; then pass "$1 ($3)"; else fail "$1" "want≈$2 got=$(printf '%q' "$3") rc=$RC err=$(printf '%q' "$ERR")"; fi
}

new_cache() { mktemp -d -p "$TMPDIR_BASE" cache.XXXXXX; }
new_snaps() { mktemp -d -p "$TMPDIR_BASE" snaps.XXXXXX; }

grp_done _fixture.sh
