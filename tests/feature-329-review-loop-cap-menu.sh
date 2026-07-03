#!/usr/bin/env bash
# Tests: bin/review-loop-cap-menu (retirement contract)
# Tags: bin, env, config, loop, scope:common
# Retirement contract for bin/review-loop-cap-menu (issue #1248).
# The script is RETIRED: any invocation now exits 2 with "RETIRED" in stderr.
#
# The cap-menu behaviors this file previously tested (AUTO_EXTEND logic,
# JSON schema, etc.) are now implemented in bin/review-loop-verdict and
# covered by:
#   - tests/feature-673-review-loop-verdict.sh Case A (AUTO_EXTEND)
#   - tests/feature-673-run-loop-verdict-integration.sh test 3 (public exit 5)
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-loop-cap-menu"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

if [[ ! -f "$SCRIPT" ]]; then
    fail "RETIRED-pre: bin/review-loop-cap-menu not found (expected to exist as RETIRED stub)"
    echo ""
    echo "$ERRORS test(s) failed."
    exit 1
fi

# RETIRED-1: any invocation → exit 2, stderr contains "RETIRED"
{
    rc=0
    STDERR_OUT=$(_timeout bash "$SCRIPT" --budget-remaining 1 --round 1 2>&1 >/dev/null) || rc=$?
    if [[ $rc -eq 2 ]]; then
        pass "RETIRED-1: exit 2 on invocation"
    else
        fail "RETIRED-1: expected exit 2, got $rc"
    fi
    if echo "$STDERR_OUT" | grep -qi "RETIRED"; then
        pass "RETIRED-1: stderr contains 'RETIRED'"
    else
        fail "RETIRED-1: stderr missing 'RETIRED'. Got: $STDERR_OUT"
    fi
}

# RETIRED-2: no args → exit 2 (RETIRED fires before arg parsing)
{
    rc=0
    _timeout bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 2 ]]; then
        pass "RETIRED-2: no-args invocation → exit 2"
    else
        fail "RETIRED-2: expected exit 2, got $rc"
    fi
}

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
