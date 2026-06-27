#!/bin/bash
# tests/feature-885-block-predicates.sh
# Tests: hooks/lib/block-predicates.js
# Tags: block-predicates, inline-skill-re, ssot, feature-885
# Original tests for #885 verified INLINE_SKILL_RE was exported as SSOT.
# After #927 the export is REMOVED — block-predicates.js no longer carries it.
# This file is reduced to a single absence assertion.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

MODULE="$AGENTS_DIR/hooks/lib/block-predicates.js"
MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/block-predicates.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$MODULE" ]; then
    skip "B1: block-predicates.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- B1: INLINE_SKILL_RE is NOT exported from block-predicates.js ------------
# Original B1-B6 verified the regex shape; after #927 the export is removed.
OUT=$(run_with_timeout 5 node -e "
const m = require('$MODULE_NODE');
if (typeof m.INLINE_SKILL_RE !== 'undefined') {
    console.error('INLINE_SKILL_RE still exported: ' + String(m.INLINE_SKILL_RE));
    process.exit(2);
}
console.log('OK');
" 2>&1)
RC=$?
if [ $RC -eq 0 ] && [ "$OUT" = "OK" ]; then
    pass "B1: INLINE_SKILL_RE absent from block-predicates.js exports"
else
    fail "B1: INLINE_SKILL_RE still present (rc=$RC, out=$OUT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
