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

# mk_sample <cache> <measured_at> <scale_in> [external_centicores] — a valid schema-2
# load/sample (bin/lib/test-host-load-sample.sh header, no allocation rows).
mk_sample() {
    local ext="${4:-$(($3 * 100))}" pool=$((11 - $3))
    [ "$pool" -ge 1 ] || pool=1
    mkdir -p "$1/load"
    printf 'schema=2\nmeasured_at=%s\nstate=ok\nhost_counter=node\nhost_busy_centicores=%s\nexternal_centicores=%s\nreserved_cores=0\nscale_in=%s\nabove=2\nbelow=0\nmem_avail_mb=unknown\nmem_total_mb=unknown\nmem_reserve_mb=unknown\nmem_scope=unknown\nmem_tests_mb=0\nmem_cap=none\npool=%s\nruns=0\n' \
        "$2" "$ext" "$ext" "$3" "$pool" > "$1/load/sample"
}

# mk_sample1 <cache> <measured_at> <scale_in> — a schema-1 sample (the previous generation).
mk_sample1() {
    mkdir -p "$1/load"
    printf 'schema=1\nmeasured_at=%s\nstate=ok\nhost_counter=system\nexternal_centicores=%s\nscale_in=%s\nabove=2\nbelow=0\n' \
        "$2" "$(($3 * 100))" "$3" > "$1/load/sample"
}

# mk_record <cache> <max-jobs-per-host> [logical-cpus] — a valid schema-3 parallelism.conf for
# this host, so mode on never starts a calibration and the measured layer supplies the limit.
mk_record() {
    local hid os cpus="${3:-64}"
    hid="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB" 2>/dev/null)"
    os="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB" 2>/dev/null)"
    printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=%s\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=%s\nmax_width_measured=%s\nwidth_limit=logical-cpu-count\n' \
        "$hid" "$os" "$2" "$cpus" "$cpus" > "$1/parallelism.conf"
}

# gen_snaps <dir> <own0|ownheavy> <ext-centicores...> — format-2 snapshots snap.1 ..
# snap.<n+1>, 2000 ms apart, cumulative counters. Interval k adds <ext_k> centicores to the
# external process 7100 (and to host busy); under ownheavy the root's child and grandchild add
# 8 cores between them on top (host counts it too). LS_MEM="<avail_kb> <total_kb> <scope>"
# adds the memory host lines.
gen_snaps() {
    local dir="$1" mode="$2" k=1 wall=100000 busy=1000000 own=0 ext=900 e
    shift 2
    mkdir -p "$dir"
    rm -f "$dir"/snap.* "$dir/count"
    _gen_one() {
        local -a m=()
        read -r -a m <<< "${LS_MEM:-}"
        {
            printf 'wall_ms=%s\nsnapshot=2\nhost_busy_ms=%s\nhost_cpus=12\n' "$wall" "$busy"
            [ "${#m[@]}" -eq 3 ] && printf 'host_mem_avail_kb=%s\nhost_mem_total_kb=%s\nhost_mem_scope=%s\n' "${m[@]}"
            printf '%s 1 500 10240 bash\n' "$ROOT_PID"
            printf '7001 %s %s 20480 node\n7002 7001 %s 20480 bash\n' "$ROOT_PID" "$own" "$own"
            printf '7100 1 %s 4096 game.exe\n' "$ext"
        } > "$dir/snap.$k"
    }
    _gen_one
    for e in "$@"; do
        k=$((k + 1)); wall=$((wall + 2000)); busy=$((busy + e * 20)); ext=$((ext + e * 20))
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
CPU12="$TMPDIR_BASE/cpu-12"; cpu_shim "$CPU12" 12
CPU4="$TMPDIR_BASE/cpu-4"; cpu_shim "$CPU4" 4
CPU16="$TMPDIR_BASE/cpu-16"; cpu_shim "$CPU16" 16

# ls_run <cache> [max-jobs-per-host] — the live run whose presence record sets base (default 12).
ls_run() {
    local t
    t="$(now_epoch)"
    mk_presence "$1" "$LIVE_SLEEP.$t.77" "$LIVE_SLEEP" "$t" "${2:-12}"
}

# snap2 <file> <wall_ms> <host_busy_ms|-> [line ...] — one format-2 snapshot; each further
# argument is one host or process line as given.
snap2() {
    local f="$1" w="$2" b="$3"
    shift 3
    {
        printf 'wall_ms=%s\nsnapshot=2\n' "$w"
        [ "$b" = - ] || printf 'host_busy_ms=%s\n' "$b"
        [ "$#" -gt 0 ] && printf '%s\n' "$@"
    } > "$f"
}

# Driver-side helpers (run inside the driver, after thl_init_dir).
ls_key() { sed -n "s/^$1=//p" "$THL_CACHE_ROOT/load/sample" 2>/dev/null | head -n 1; }
ls_age() {
    local f="$THL_CACHE_ROOT/load/sample" t
    [ -f "$f" ] || return 0
    t=$(($(date +%s) - ${1:-3}))
    sed -i "s/^measured_at=.*/measured_at=$t/" "$f"
}
# ls_ticks <n> — n sampler ticks, the sample aged past one heartbeat (2s) before each later tick.
# held= is the retired held_samples key; it must stay empty (the sample no longer carries it).
ls_ticks() {
    local i
    for ((i = 1; i <= $1; i++)); do
        [ "$i" -gt 1 ] && ls_age 3
        thl_load_tick
        printf 'tick%s state=%s ext=%s scale=%s pool=%s res=%s above=%s below=%s held=%s\n' "$i" "$(ls_key state)" \
            "$(ls_key external_centicores)" "$(ls_key scale_in)" "$(ls_key pool)" "$(ls_key reserved_cores)" \
            "$(ls_key above)" "$(ls_key below)" "$(ls_key held_samples)"
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
    'declare -F _thl_sample_read >/dev/null 2>&1 || { [ -f "$DRV_SAMPLE_LIB" ] && . "$DRV_SAMPLE_LIB"; }' \
    'declare -F _thl_alloc_run >/dev/null 2>&1 || { [ -f "$DRV_ALLOC_LIB" ] && . "$DRV_ALLOC_LIB"; }' \
    'declare -F thl_load_tick >/dev/null 2>&1 && declare -F _thl_load_compute >/dev/null 2>&1 || { echo "DRV: load lib not loaded (not implemented)" >&2; exit 93; }' \
    '. "$DRV_HELPERS"' 'thl_init_dir' \
    'eval "$1"' > "$LOAD_DRV"

OUT=""
ERR=""
RC=0
# load_drv <cache> <snap-dir> [NAME=VAL ...] -- <snippet> — sets OUT / ERR / RC.
# Defaults: mode on, heartbeat 2s, the probe stub, 12 logical CPUs (with max jobs per host 12
# that reserves 0 cores, so the external load counts in full).
load_drv() {
    local cache="$1" snaps="$2"; shift 2
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/drv.out" errf="$TMPDIR_BASE/drv.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 90 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" "DRV_LOAD_LIB=$LOAD_LIB" \
            "DRV_PROBE_LIB=$PROBE_LIB" "DRV_SAMPLE_LIB=$SAMPLE_LIB" "DRV_ALLOC_LIB=$ALLOC_LIB" "DRV_HELPERS=$DRV_HELPERS" "RUN_ALL_CACHE_DIR=$cache" "LS_SNAP_DIR=$snaps" \
            AUTO_CONFIG_TEST_MAX_JOBS=on TEST_LANES_HEARTBEAT=2 TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 \
            "TEST_LANES_LOAD_PROBE_CMD=$PROBE_STUB" "PATH=$CPU12:$PATH" ${envs[@]+"${envs[@]}"} bash "$LOAD_DRV" "$1"
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

# The pure computation: CD holds the snapshots and the roots file (the own root only).
CD="$TMPDIR_BASE/compute"
mkdir -p "$CD"
printf '%s\n' "$ROOT_PID" > "$CD/roots"
# compute <prev> <cur> [NAME=VAL ...] — OUT holds the key=value lines of one computation.
compute() {
    local p="$1" c="$2"; shift 2
    load_drv "$(new_cache)" "$CD" "$@" -- "_thl_load_compute $(printf '%q' "$p") $(printf '%q' "$c") $(printf '%q' "$CD/roots")"
}
# has_line <text> <line> — 1 when <line> is one whole line of <text>, else 0.
has_line() { printf '%s\n' "$1" | grep -cxF -- "$2"; }

grp_done _fixture.sh
