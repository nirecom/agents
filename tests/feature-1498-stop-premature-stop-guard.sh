#!/bin/bash
# tests/feature-1498-stop-premature-stop-guard.sh
# Tests: hooks/stop-premature-stop-guard.js
# Tags: scope:issue-specific
# Tests for issue #1498 — Stop hook stop-premature-stop-guard.js (NEW).
#
# L3 gap (what this test does NOT catch):
# - Real Claude Code Stop hook invocation wiring (settings.json entry actually fires the hook)
# - Real stop_hook_active env propagation in live Claude sessions
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

SCRIPT_DIR="$AGENTS_DIR/tests/feature-1498-stop-premature-stop-guard"

# shellcheck source=./feature-1498-stop-premature-stop-guard/state-seeds.sh
. "$SCRIPT_DIR/state-seeds.sh"
# shellcheck source=./feature-1498-stop-premature-stop-guard/t-hook-integration.sh
. "$SCRIPT_DIR/t-hook-integration.sh"
# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

# Exit 77 (skip) when nothing ran because the source is unimplemented — this keeps
# the suite from reporting a false green while the hook does not yet exist. Once
# the hook lands, PASS/FAIL become non-zero and the suite exits on the FAIL count.
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    exit 77
fi
exit $FAIL
