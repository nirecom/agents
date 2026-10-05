#!/usr/bin/env bash
# bin/test-lanes-status.sh — list the host-wide test lanes (#2455) and who holds them.
# Read-only: never reclaims, never creates slots/. Design: docs/architecture/claude-code/test-host-lanes.md.
# Usage: bash bin/test-lanes-status.sh [-h|--help]
# Output: `max_jobs_per_host=<N> source=<env|dotenv|measured|default> [record=<reason>]
#   [measured_on=<os> now=<os>]`, then one
#   `lane.<i><TAB>kind<TAB>pid<TAB>env<TAB>age_s<TAB>state` row per lane, or `no test lanes held`.
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
