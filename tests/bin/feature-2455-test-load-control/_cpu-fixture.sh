#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_cpu-fixture.sh — CPU-count shims and the
# parallelism.conf builder shared by cpu-ceiling-cases.sh and parallelism-record-cases.sh.
# Sourced after _fixture.sh and _lanes-fixture.sh (L12_HID, L_OS_NOW).

# shellcheck source=../../lib/tool-shim-path.sh
. "$AGENTS_ROOT/tests/lib/tool-shim-path.sh"

CC_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
CC_OFF=AUTO_CONFIG_TEST_MAX_JOBS=off
# shellcheck disable=SC2016 # expanded by the driver
CC_CPU='run_all_logical_cpu_count; echo "rc=$?"; echo "n=${RUN_ALL_LOGICAL_CPU_COUNT-unset}"'
# shellcheck disable=SC2016
CC_MAX='thl_max_jobs_per_host; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"; echo "cap=${THL_CAP_NOTE-}"'
# shellcheck disable=SC2016
CC_PLAN='thl_plan 2; echo "note=${THL_NOTE-}"'
# shellcheck disable=SC2016
CC_LEASE='thl_init_dir; thl_run_all_lease 2 0; echo "rc=$?"; echo "note=${THL_NOTE-}"; thl_release_all'
# shellcheck disable=SC2016
CC_READ='run_all_cache_read "$RUN_ALL_CACHE_DIR/parallelism.conf"; echo "rc=$?"; echo "r=${RUN_ALL_CACHE_REASON-}"; echo "m=${RUN_ALL_CACHE_MAX_JOBS_PER_HOST-}"; echo "lc=${RUN_ALL_CACHE_LOGICAL_CPU_COUNT-}"; echo "mw=${RUN_ALL_CACHE_MAX_WIDTH_MEASURED-}"; echo "wl=${RUN_ALL_CACHE_WIDTH_LIMIT-}"; echo "lg=${RUN_ALL_CACHE_IS_LEGACY-}"'

# cc_cpu <n> — echoes a PATH dir whose nproc prints <n> (one dir per value, built once).
cc_cpu() {
    local d="$TMPDIR_BASE/cc-cpu-$1"
    [ -x "$d/nproc" ] || cpu_shim "$d" "$1"
    printf '%s' "$d"
}
# A PATH with no nproc and no getconf (sysctl is never in the base); NUMBER_OF_PROCESSORS=
# (empty, so invalid) is passed with it to close the last source.
CC_BARE="$(tsp_base_path "$TMPDIR_BASE/cc-bare" nproc getconf)" || CC_BARE=""
[ -n "$CC_BARE" ] && pass "CPU precondition: a PATH without nproc/getconf builds" || fail "CPU precondition: tsp_base_path failed"
CC_UNKNOWN=("PATH=$CC_BARE" "NUMBER_OF_PROCESSORS=")

# cc_rec <cache> [key=val | -key | +key=val]... — a parallelism.conf for this host. Defaults are a
# well-formed schema-3 record measured at 1024 CPUs up to that ceiling; key=val replaces a line,
# -key drops it, +key=val appends one.
cc_rec() {
    local cache="$1" a k i; shift
    local -a lines=("schema=3" "host_id=$L12_HID" "os=$L_OS_NOW" "max_jobs_per_host=5" \
        "measured_at=2026-01-01T00:00:00Z" "sample_size=3" "repeat=1" "logical_cpu_count=1024" \
        "max_width_measured=1024" "width_limit=logical-cpu-count")
    for a in "$@"; do
        case "$a" in
            -*) k="${a#-}"
                for i in "${!lines[@]}"; do [ "${lines[$i]%%=*}" = "$k" ] && unset "lines[$i]"; done ;;
            +*) lines+=("${a#+}") ;;
            *) k="${a%%=*}"
                for i in "${!lines[@]}"; do [ "${lines[$i]%%=*}" = "$k" ] && lines[i]="$a"; done ;;
        esac
    done
    rm -rf "$cache"; mkdir -p "$cache"
    printf '%s\n' "${lines[@]}" > "$cache/parallelism.conf"
}
CC_N=0
cc_dir() { CC_N=$((CC_N + 1)); printf '%s' "$TMPDIR_BASE/cc-$CC_N"; }

grp_done _cpu-fixture.sh
