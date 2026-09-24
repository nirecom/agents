#!/bin/bash
# tests/refactor-1202-supervisor-guard-split.sh
# Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/detect.js
# Tags: supervisor, em-supervisor, hook, refactor, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if hooks/supervisor-guard.js is
#   not wired, existing behavioral tests still pass because they invoke the hook directly
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OVERALL=0

run_sub() {
    local script="$1"
    bash "$script"
    local rc=$?
    [ $rc -ne 0 ] && OVERALL=1
    return $rc
}

echo "=== structural (cases 1-15) ==="
run_sub "$SCRIPT_DIR/refactor-1202-supervisor-guard-split/structural.sh"

echo ""
echo "=== edge (cases 16-24, 40) ==="
run_sub "$SCRIPT_DIR/refactor-1202-supervisor-guard-split/edge.sh"

echo ""
echo "=== behavioral (cases 25-39) ==="
run_sub "$SCRIPT_DIR/refactor-1202-supervisor-guard-split/behavioral.sh"

exit $OVERALL
