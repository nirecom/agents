#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc/_fixture.sh — presence records, lanes, the previous
# sample, the probe stub and the tick driver. Sourced FIRST by the dispatcher.
# Every presence record says max jobs per host 16 and the CPU shim says 16 logical CPUs, so
# base 16, pool 15, TOP 15 and reserved cores 0 (external load counts in full).

now_epoch() { printf '%(%s)T' -1; }
AL_T0="$(now_epoch)"
# The driver's heartbeat: long enough that a tick on a loaded host stays inside the two-heartbeat
# write window and the probe timeout clamp. A sample is due at one heartbeat, fresh to three.
AL_HB=30

# The root pid as the load lib sees it: the Windows PID when /proc/<pid>/winpid exists.
ROOT_PID="$LIVE_SLEEP"
if [ -r "/proc/$LIVE_SLEEP/winpid" ]; then
    _w="$(cat "/proc/$LIVE_SLEEP/winpid" 2>/dev/null)"
    [[ $_w =~ ^[0-9]+$ ]] && ROOT_PID="$_w"
fi

# tok <n> — run n's token; a smaller n started earlier.
tok() { printf '%s.%s.%s' "$LIVE_SLEEP" "$((AL_T0 - 1000 + $1))" "$1"; }

# mk_slot <cache> <i> <pid> <token> — one lane held by <pid> under <token>.
mk_slot() {
    local d="$1/slots/lane.$2" hb
    hb="$(now_epoch)"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\n' "$3" "$OSTYPE" "$hb" "$4" > "$d/owner"
    printf '%s\n' "$hb" > "$d/hb"
}

# al_run <cache> <n> [demand] [max-jobs-per-host] [pid] — run n's presence record.
al_run() {
    local t d="$1/runs/run.$(tok "$2")"
    t="$(tok "$2")"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\nmax_jobs_per_run=%s\nmax_jobs_per_host=%s\n' \
        "${5:-$LIVE_SLEEP}" "$OSTYPE" "$((AL_T0 - 1000 + $2))" "$t" "${3:-1000}" "${4:-16}" > "$d/owner"
    now_epoch > "$d/hb"
}

# al_lanes <cache> <n> <count> <first-lane> — run n holds lanes first..first+count-1.
al_lanes() {
    local i
    for ((i = $4; i < $4 + $3; i++)); do mk_slot "$1" "$i" "$LIVE_SLEEP" "$(tok "$2")"; done
}

# al_prev <cache> [key=val ...] [-- <row> ...] — the previous sample, one heartbeat old (fresh, due).
al_prev() { local c="$1"; shift; ls2_write "$c" "$AL_HB" "$@"; }

# row <n> <w> <ss> <fs> <decided_by> — one alloc row argument for al_prev.
row() { printf '%s=%s %s %s %s' "$(tok "$1")" "$2" "$3" "$4" "$5"; }

# mk_record <cache> — a schema-3 record of max jobs per host 16 at 16 CPUs (mode on).
mk_record() {
    local hid os
    hid="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB" 2>/dev/null)"
    os="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB" 2>/dev/null)"
    printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=16\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=16\nmax_width_measured=16\nwidth_limit=logical-cpu-count\n' \
        "$hid" "$os" > "$1/parallelism.conf"
}

# al_snaps <cache> <snap-dir> <spec> ... — mode on: the record, the previous snapshot
# (load/snapshot.2, memory per AL_PREV_MEM) and the stub's snap.<k> per spec: FAIL, or
# `<ext-centicores> [<avail_kb> <total_kb> <scope>]`.
al_snaps() {
    local c="$1" d="$2" k=0 wall=100000 busy=1000000 ext=900 s
    shift 2
    mk_record "$c"
    mkdir -p "$c/load" "$d"
    # shellcheck disable=SC2086
    ls2_snap "$c/load/snapshot.2" "$wall" "$busy" "$ROOT_PID" "$ext" ${AL_PREV_MEM:-}
    for s in "$@"; do
        k=$((k + 1))
        if [ "$s" = FAIL ]; then printf 'FAIL\n' > "$d/snap.$k"; continue; fi
        set -- $s
        wall=$((wall + 2000)); busy=$((busy + $1 * 20)); ext=$((ext + $1 * 20))
        shift
        ls2_snap "$d/snap.$k" "$wall" "$busy" "$ROOT_PID" "$ext" "$@"
    done
}

# The probe stub: call n serves <LS_SNAP_DIR>/snap.<n>; a missing file or FAIL exits 1.
PROBE_STUB="$TMPDIR_BASE/probe-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' 'd="${LS_SNAP_DIR:?}"' 'n=0; [ -f "$d/count" ] && n="$(cat "$d/count")"' \
    'n=$((n + 1)); printf "%s\n" "$n" > "$d/count"' 'f="$d/snap.$n"' '[ -f "$f" ] || exit 1' \
    '[ "$(head -n 1 "$f")" = FAIL ] && exit 1' 'cat "$f"' > "$PROBE_STUB"
chmod +x "$PROBE_STUB"
probe_calls() { if [ -f "$1/count" ]; then cat "$1/count"; else printf '0'; fi; }

CPU16="$TMPDIR_BASE/cpu-16"
mkdir -p "$CPU16"
printf '#!%s\nprintf "%%s\\n" 16\n' "$(type -P bash)" > "$CPU16/nproc"
chmod +x "$CPU16/nproc"

# Driver-side helpers. al_tick <i>: age the sample to one heartbeat (i > 1), one tick, then
# the sample with every line prefixed `t<i>.`. al_fill <token>: hold as many lanes as the row.
al_tick() {
    local f="$THL_CACHE_ROOT/load/sample" t
    if [ "$1" -gt 1 ] && [ -f "$f" ]; then
        t=$(($(date +%s) - TEST_LANES_HEARTBEAT)); sed -i "s/^measured_at=.*/measured_at=$t/" "$f"
    fi
    thl_load_tick
    sed "s/^/t$1./" "$f" 2>/dev/null
}
al_fill() {
    local w n=0 i=1 d t
    w="$(sed -n "s/^alloc\.${1//./\\.}=\([0-9]*\) .*/\1/p" "$THL_CACHE_ROOT/load/sample" 2>/dev/null)"
    for d in "$THL_CACHE_ROOT"/slots/lane.*; do
        [ -f "$d/owner" ] || continue
        t="$(sed -n 's/^token=//p' "$d/owner")"; [ "$t" = "$1" ] && n=$((n + 1))
    done
    while [ "$n" -lt "${w:-0}" ] && [ "$i" -le 15 ]; do
        [ -d "$THL_CACHE_ROOT/slots/lane.$i" ] || { mk_slot "$THL_CACHE_ROOT" "$i" "$LIVE" "$1"; n=$((n + 1)); }
        i=$((i + 1))
    done
}
DRV_HELPERS="$TMPDIR_BASE/alloc-drv-helpers.sh"
declare -f now_epoch mk_slot al_tick al_fill > "$DRV_HELPERS"

ALLOC_DRV="$TMPDIR_BASE/alloc-drv.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$DRV_PAR_LIB" 2>/dev/null || { echo "DRV: parallelism lib missing" >&2; exit 90; }' \
    '. "$DRV_LANES_LIB" 2>/dev/null || { echo "DRV: lanes lib missing" >&2; exit 91; }' \
    'declare -F _thl_sample_read >/dev/null 2>&1 || { [ -f "$DRV_SAMPLE_LIB" ] && . "$DRV_SAMPLE_LIB"; }' \
    'declare -F _thl_alloc_run >/dev/null 2>&1 || { [ -f "$DRV_ALLOC_LIB" ] && . "$DRV_ALLOC_LIB"; }' \
    'declare -F _thl_sample_read >/dev/null 2>&1 && declare -F thl_load_tick >/dev/null 2>&1 || { echo "DRV: sample lib not loaded (not implemented)" >&2; exit 94; }' \
    '. "$DRV_HELPERS"' 'thl_init_dir' 'thl_max_jobs_per_host' \
    'eval "$1"' > "$ALLOC_DRV"

OUT=""
ERR=""
RC=0
# al_drv <cache> <snap-dir> [NAME=VAL ...] -- <snippet> — sets OUT / ERR / RC. Defaults: mode
# off, max jobs per host 16, 16 CPUs, heartbeat AL_HB, the probe stub.
al_drv() {
    local cache="$1" snaps="$2"; shift 2
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/drv.out" errf="$TMPDIR_BASE/drv.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 90 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" "DRV_SAMPLE_LIB=$SAMPLE_LIB" \
            "DRV_ALLOC_LIB=$ALLOC_LIB" "DRV_HELPERS=$DRV_HELPERS" "RUN_ALL_CACHE_DIR=$cache" "LS_SNAP_DIR=$snaps" \
            AUTO_CONFIG_TEST_MAX_JOBS=off TEST_MAX_JOBS_PER_HOST=16 "TEST_LANES_HEARTBEAT=$AL_HB" TEST_LANES_WAIT_INTERVAL=1 \
            TEST_LANES_WAIT_CAP=3 "TEST_LANES_LOAD_PROBE_CMD=$PROBE_STUB" "LIVE=$LIVE_SLEEP" "PATH=$CPU16:$PATH" \
            ${envs[@]+"${envs[@]}"} bash "$ALLOC_DRV" "$1"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}
ON="AUTO_CONFIG_TEST_MAX_JOBS=on"

# kv_of <text> <key> — value of the first `key=value` line (key is a literal).
kv_of() { printf '%s\n' "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }
# tk <tick> <key> / trow <tick> <n> — a header value / run n's alloc row in OUT after al_tick.
tk() { kv_of "$OUT" "t$1.$2"; }
trow() { kv_of "$OUT" "t$1.alloc.$(tok "$2")"; }
# wsum <tick> — the sum of every row's width at that tick.
wsum() { printf '%s\n' "$OUT" | awk -v p="t$1.alloc." 'index($0, p) == 1 { sub(/^[^=]*=/, ""); s += $1 } END { print s + 0 }'; }

new_cache() { mktemp -d -p "$TMPDIR_BASE" cache.XXXXXX; }
new_snaps() { mktemp -d -p "$TMPDIR_BASE" snaps.XXXXXX; }

# Memory in kB: 16 GiB total gives reserve 2048 MB; 100000 MB total gives reserve 10000 MB.
GIB16=16777216
MB100K=102400000
mb() { printf '%s' "$(($1 * 1024))"; }

grp_done _fixture.sh
