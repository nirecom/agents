#!/usr/bin/env bash
# tests/bin/feature-2558-worker-log-location.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/worker-log.js, bin/worker-dispatch/fsguard.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, worker-log, fsguard, symlink, security, table-driven, TL1, TL2, scope:issue-specific
#
# Issue #2558 — worker timestamped logs leave PLANS_DIR: <WF>/<sid>.control when
# the sid is known, <WF>/worker-logs otherwise, never through a symlinked dir.
# Entrypoint only sources the case files and tallies; cases live in the sibling dir.
set -u

# TL3 gap: a real gh/git/uv run is stubbed, so only the dispatcher's own log
# writes are measured, not what a real child prints into them.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD2558_INNER:-}" ]; then
    _WD2558_INNER=1 timeout 600 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
for tool in git node; do
    if ! command -v "$tool" >/dev/null 2>&1; then echo "SKIP: $tool is not on PATH"; exit 77; fi
done

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2558-worker-log-location"
. "$CASE_DIR/setup.sh"
. "$CASE_DIR/matrix.sh"
. "$CASE_DIR/symlink.sh"
# units.sh runs c2 / c3 / c4 itself, each inside its own column-0 case markers.
. "$CASE_DIR/units.sh"

case_begin "c1-c5-worker-log-location-matrix" "bin/worker-dispatch.js"
group_matrix
case_end

case_begin "c6-log-dir-symlink-refused" "bin/worker-dispatch.js"
group_symlink
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
