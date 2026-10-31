#!/usr/bin/env bash
# bin/test-lanes-status.sh — list the host-wide test lanes (#2455) and who holds them.
# Read-only: never reclaims, never creates slots/. Design: docs/architecture/claude-code/test-host-lanes.md.
# Usage: bash bin/test-lanes-status.sh [-h|--help]
# Output: `max_jobs_per_host=<N> source=<env|dotenv|measured|default> [record=<reason>]
#   [measured_on=<os> now=<os>] mode=<on|off> runs=<n>`, load/sample (`load state=none` or `load state=
#   ... pool=`, #2692) then `load is the run-all lane allocation sample`, one `lane.<i>` row
#   (kind pid env age_s state) per lane or `no test lanes held`, then one `run.<k>` row per presence
#   record plus width ssthresh per_run_lane_cap decided_by (per-run-cap|cpu-load-limit|memory-limit|slow-start; `-`).
# state: alive | stale-dead-pid | stale-ttl | foreign | ownerless.
# Exit: 0 = listed, 2 = usage error.
set -u

usage() {
    printf 'Usage: bash bin/test-lanes-status.sh [-h|--help]\n'
    printf 'Lists the host-wide test lanes shared by find-tests-for-source.sh and tests/run-all.sh.\n'
}

case "$#:${1:-}" in
    0:) ;;
    1:-h|1:--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

_TLS_DIR="${BASH_SOURCE[0]%/*}"
[ "$_TLS_DIR" != "${BASH_SOURCE[0]}" ] || _TLS_DIR="."
# shellcheck source=lib/run-all-parallelism.sh
. "$_TLS_DIR/lib/run-all-parallelism.sh" || exit 2
# shellcheck source=lib/test-host-lanes.sh
. "$_TLS_DIR/lib/test-host-lanes.sh" || exit 2

thl_init_dir
thl_status
exit 0
