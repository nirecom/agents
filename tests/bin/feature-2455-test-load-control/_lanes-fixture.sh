#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_lanes-fixture.sh — lanes snippets and the
# host/OS record helpers shared by the lanes, lanes-limits, cpu-ceiling,
# parallelism-record and auto-config case files. Sourced after _fixture.sh.

LIVE_PID="$$"
# Snippet shared by the lease cases: print the result and the held lanes.
LEASE_SNIP='thl_init_dir; thl_find_tests_lease; rc=$?; echo "rc=$rc"; echo "drvpid=$$"; echo "held=${TEST_LANES_HELD-}"'
L12_SNIP='thl_max_jobs_per_host; echo "b=${THL_MAX_JOBS_PER_HOST-}/${THL_MAX_JOBS_PER_HOST_SOURCE-}"'
L12_HID="$(bash -c '. "$1"; run_all_host_id' _ "$PAR_LIB")"
# The current OS attribute, from the real lib (empty while run_all_os_attr is absent).
L_OS_NOW="$(bash -c '. "$1"; command -v run_all_os_attr >/dev/null 2>&1 && run_all_os_attr' _ "$PAR_LIB")"

# l12_conf <cache> <max> [os] — a schema-3 measured record for this host, measured at the
# fixture's 1024 logical CPUs (CPU_SHIM_DIR) up to that ceiling: it raises no recalibrate advice.
l12_conf() {
    mkdir -p "$1"
    printf 'schema=3\nhost_id=%s\nos=%s\nmax_jobs_per_host=%s\nmeasured_at=2026-01-01T00:00:00Z\nsample_size=3\nrepeat=1\nlogical_cpu_count=1024\nmax_width_measured=1024\nwidth_limit=logical-cpu-count\n' \
        "$L12_HID" "${3:-$L_OS_NOW}" "$2" > "$1/parallelism.conf"
}

# dotenv_stub <name> <value> — sets DOTENV_STUB to a resolver that prints <value>
# for <name> only and leaves <stub>.called behind whenever it is launched.
DOTENV_N=0
dotenv_stub() {
    DOTENV_N=$((DOTENV_N + 1))
    DOTENV_STUB="$TMPDIR_BASE/dotenv-stub-$DOTENV_N.sh"
    printf '#!/usr/bin/env bash\n: > %q\nfor a in "$@"; do [ "$a" = %q ] && { printf "%%s\\n" %q; exit 0; }; done\nexit 0\n' \
        "$DOTENV_STUB.called" "$1" "$2" > "$DOTENV_STUB"
    chmod +x "$DOTENV_STUB"
}

# hb_wait_refresh <hb-file> <secs> — inside a driver snippet: poll every 0.2 s until the
# heartbeat file no longer reads 1000, at most <secs> seconds (the old fixed sleep).
# shellcheck disable=SC2016 # expanded by the driver
HB_WAIT_FN='hb_wait_refresh() { local v="" i=0; while [ "$i" -lt $(( $2 * 5 )) ]; do sleep 0.2; i=$((i + 1)); read -r v < "$1" 2>/dev/null || v=""; [ -n "$v" ] && [ "$v" != 1000 ] && return 0; done; return 1; }'

grp_done _lanes-fixture.sh
