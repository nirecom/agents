#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share/_fixture.sh — shared helpers, the lib
# driver and the run-all fixture setup. Sourced FIRST by the dispatcher.

now_epoch() { printf '%(%s)T' -1; }

# dead_pid — a pid that has already exited.
dead_pid() {
    local p
    bash -c 'exit 0' &
    p=$!
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

# mk_slot <cache-root> <i> <pid> [token] — one lane held by <pid>.
mk_slot() {
    local d="$1/slots/lane.$2" hb tok="${4:-}"
    hb="$(now_epoch)"
    [ -n "$tok" ] || tok="$3.$hb.4242"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\n' "$3" "$OSTYPE" "$hb" "$tok" > "$d/owner"
    printf '%s\n' "$hb" > "$d/hb"
}

# mk_presence <cache> <token> <pid> <start> [max-jobs-per-host] [demand] [hb] [env]
# One presence record runs/run.<token> (owner + hb), the format the share lib writes.
mk_presence() {
    local d="$1/runs/run.$2" hb="${7:-}"
    [ -n "$hb" ] || hb="$(now_epoch)"
    mkdir -p "$d"
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=%s\nmax_jobs_per_run=%s\nmax_jobs_per_host=%s\n' \
        "$3" "${8:-$OSTYPE}" "$4" "$2" "${6:-1000}" "${5:-12}" > "$d/owner"
    printf '%s\n' "$hb" > "$d/hb"
}

# lane_names <cache> — held lane.* basenames, space-joined.
lane_names() {
    local d res=""
    for d in "$1"/slots/lane.*; do
        [ -d "$d" ] && res="$res ${d##*/}"
    done
    printf '%s' "${res# }"
}

# run_names <cache> — presence record basenames (run.<token>), space-joined.
run_names() {
    local d res=""
    for d in "$1"/runs/run.*; do
        [ -d "$d" ] && res="$res ${d##*/}"
    done
    printf '%s' "${res# }"
}

grave_count() {
    local d n=0
    for d in "$1"/slots/.grave.* "$1"/runs/.grave.*; do
        [ -e "$d" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# own_lanes [token] — inside the driver: lanes whose owner token is <token> (default THL_TOKEN).
own_lanes() {
    local d n=0 t want="${1-$THL_TOKEN}"
    for d in "$THL_CACHE_ROOT"/slots/lane.*; do
        [ -f "$d/owner" ] || continue
        t="$(sed -n 's/^token=//p' "$d/owner")"
        [ -n "$want" ] && [ "$t" = "$want" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# drv_inv <label> — inside the driver: `<label>=g<GRANTED>s<|SLOTS|>o<own lanes>`.
drv_inv() {
    local s=0 i
    for i in $THL_SLOTS; do s=$((s + 1)); done
    printf '%s=g%ss%so%s\n' "$1" "$THL_GRANTED" "$s" "$(own_lanes)"
}

# fs_row <pool> <demand...> — inside the driver: every position's share, space-joined.
fs_row() {
    local pool="$1" n i out=""; shift
    n=$#
    for ((i = 0; i < n; i++)); do
        THL_FAIR_SHARE=""
        _thl_fair_share_compute "$pool" "$i" "$@"
        out="$out ${THL_FAIR_SHARE:-?}"
    done
    printf '%s\n' "${out# }"
}

# row_sum <row> — the sum of a space-joined row ("?" counts as 0).
row_sum() {
    local v s=0
    for v in $1; do [[ $v =~ ^[0-9]+$ ]] && s=$((s + v)); done
    printf '%s' "$s"
}

DRV_HELPERS="$TMPDIR_BASE/share-drv-helpers.sh"
declare -f now_epoch mk_slot mk_presence own_lanes drv_inv fs_row > "$DRV_HELPERS"

cpu_shim() {
    mkdir -p "$1"
    printf '#!%s\nprintf "%%s\\n" %q\n' "$(type -P bash)" "$2" > "$1/nproc"
    chmod +x "$1/nproc"
}
CPU_SHIM_DIR="$TMPDIR_BASE/cpu-shim-1024"
cpu_shim "$CPU_SHIM_DIR" 1024

# The driver sources both libs and requires the share lib (#2687 ③) to have been loaded by them.
LANES_DRV="$TMPDIR_BASE/share-drv.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$DRV_PAR_LIB" 2>/dev/null || { echo "DRV: parallelism lib missing" >&2; exit 90; }' \
    '. "$DRV_LANES_LIB" 2>/dev/null || { echo "DRV: lanes lib missing" >&2; exit 91; }' \
    'declare -F _thl_fair_share_compute >/dev/null 2>&1 || { echo "DRV: share lib not loaded (not implemented)" >&2; exit 92; }' \
    '. "$DRV_HELPERS"' \
    'eval "$1"' > "$LANES_DRV"

OUT=""
ERR=""
RC=0
# lanes_drv <cache> [NAME=VAL ...] -- <snippet> — sets OUT / ERR / RC. Mode off: no load scale-in.
lanes_drv() {
    local cache="$1"; shift
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/drv.out" errf="$TMPDIR_BASE/drv.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" "DRV_HELPERS=$DRV_HELPERS" \
            "RUN_ALL_CACHE_DIR=$cache" TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 AUTO_CONFIG_TEST_MAX_JOBS=off \
            "PATH=$CPU_SHIM_DIR:$PATH" ${envs[@]+"${envs[@]}"} bash "$LANES_DRV" "$1"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}

# lanes_drv_bg <cache> <out> <err> [NAME=VAL ...] -- <snippet> — sets BG_PID.
lanes_drv_bg() {
    local cache="$1" outf="$2" errf="$3"; shift 3
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" "DRV_HELPERS=$DRV_HELPERS" \
            "RUN_ALL_CACHE_DIR=$cache" TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 AUTO_CONFIG_TEST_MAX_JOBS=off \
            "PATH=$CPU_SHIM_DIR:$PATH" ${envs[@]+"${envs[@]}"} bash "$LANES_DRV" "$1"
    ) >"$outf" 2>"$errf" &
    BG_PID=$!
}

# kv_of <text> <key> — value of the first `key=value` line in <text>.
kv_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# has_line <text> <fixed-string> — 0 when <text> contains the string.
has_line() { printf '%s\n' "$1" | grep -qF -- "$2"; }

# new_cache — a fresh, empty cache root under TMPDIR_BASE.
new_cache() { mktemp -d -p "$TMPDIR_BASE" cache.XXXXXX; }

# ── run-all fixture (feature-1832 _lib; fx_init is not called: it would replace our trap) ─
# shellcheck source=../../tests/feature-1832-run-all-parallel/_lib.sh
. "$AGENTS_ROOT/tests/tests/feature-1832-run-all-parallel/_lib.sh"
FX_TMP_ROOT="$TMPDIR_BASE/fx"
FX_CACHE_DIR="$FX_TMP_ROOT/run-all-cache"
fx_drop_ambient_controls
export RUN_ALL_CONFIG_VAR_CMD="$NO_CONFIG_VAR_CMD"
export RUN_ALL_REGISTRY_LIB="$FX_REPO_ROOT/bin/lib/test-language-registry.sh"
mkdir -p "$FX_CACHE_DIR"
FX_PATH_PREFIX="$CPU_SHIM_DIR"
R_LANE_VARS="TEST_LANES TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN TEST_LANES_HELD TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP AUTO_CONFIG_TEST_MAX_JOBS"

r_reset() {
    # shellcheck disable=SC2086
    unset $R_LANE_VARS FX_WITH_LANES
    rm -rf "$FX_CACHE_DIR/slots" "$FX_CACHE_DIR/runs" "$FX_CACHE_DIR/load"
}

# fs_dummy <root> <id> <tag> <shared-log> <secs> — a test that logs `+<tag> <ms> <id>` / `-<tag> <ms> <id>`
# to one log shared by several run-all roots (mkdir lock), so cross-run concurrency is measurable.
fs_dummy() {
    local f="$1/tests/bin/$2.sh"
    {
        printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\n'
        printf 'echo "$$" > %q\n' "$1/pids/$2.self"
        printf 'L=%q; K="$L.lock"\n' "$4"
        printf '_ms() { local n; n="$(date +%%s%%3N 2>/dev/null)"; case "$n" in *N*|"") n="$(( $(date +%%s) * 1000 ))" ;; esac; printf %%s "$n"; }\n'
        printf '_pk() { local n=0; while ! mkdir "$K" 2>/dev/null; do n=$((n + 1)); [ "$n" -gt 200000 ] && break; done; printf "%%s %%s %%s\\n" "$1" "$(_ms)" %q >> "$L"; rmdir "$K" 2>/dev/null; }\n' "$2"
        printf '_pk "+%s"\nsleep %s\n_pk "-%s"\nexit 0\n' "$3" "$5" "$3"
    } > "$f"
    chmod +x "$f" 2>/dev/null || true
}

# fs_root <n> <tag> <shared-log> <secs> — a lanes-enabled fixture root with <n> fs_dummy tests.
fs_root() {
    local root i
    root="$(FX_WITH_LANES=1 fx_new_root)"
    for ((i = 1; i <= $1; i++)); do fs_dummy "$root" "$2$i" "$2" "$3" "$4"; done
    echo "$root"
}

# log_peak <log> — the highest number of tests inside their body at once, across tags.
log_peak() { fx_peak_of "$1"; }

# log_overlap <log> <tagA> <tagB> — 1 when a test of each tag was inside its body at the same time.
log_overlap() {
    [ -f "$1" ] || { printf '0'; return 0; }
    awk -v a="+$2" -v b="+$3" -v ea="-$2" -v eb="-$3" '
        $1 == a { na++ } $1 == ea { na-- } $1 == b { nb++ } $1 == eb { nb-- }
        { if (na > 0 && nb > 0) o = 1 }
        END { printf "%d", o + 0 }' "$1"
}

# wait_grep <secs> <file> <fixed-string> — 0 when the file carries the string in time (0.5s polls).
wait_grep() {
    local n=0 lim=$(($1 * 2))
    while [ "$n" -lt "$lim" ]; do
        grep -qF -- "$3" "$2" 2>/dev/null && return 0
        sleep 0.5
        n=$((n + 1))
    done
    return 1
}

# bg_stop <pid> <root> — make sure a background run-all and its tests are gone.
bg_stop() {
    fx_wait_gone 2 "$1" || { kill -INT "$1" 2>/dev/null; fx_wait_gone 10 "$1" || fx_kill_tree "$1"; }
    wait "$1" 2>/dev/null
    local p
    for p in $(fx_recorded_pids "$2"); do fx_kill_tree "$p"; done
    return 0
}

grp_done _fixture.sh
