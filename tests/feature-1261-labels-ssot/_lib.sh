#!/bin/bash
# tests/feature-1261-labels-ssot/_lib.sh — shared scaffolding
#
# Sourced by each split file (via a BASH_SOURCE-relative path) so they can also
# run standalone. Provides the scaffolding common to all test files:
#   - AGENTS_DIR constant
#   - PASS / FAIL counters and pass / fail helpers
#   - assert_eq (table-driven equality assertion)
#   - run_with_timeout wrapper
#
# Each split file keeps its OWN file-specific mock factory, setup_mock/
# teardown_mock, and file-specific env knobs — those differ per source-under-test
# and are intentionally NOT shared here.
#
# NOT a test file: no # Tests:/# Tags: frontmatter; excluded from the
# dispatcher's SPLIT_GROUPS.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_FEATURE_1261_LIB_SOURCED:-}" ]; then
    return 0
fi
_FEATURE_1261_LIB_SOURCED=1

set -u

# Repo root, resolved relative to this lib (tests/feature-1261-labels-ssot/).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Table-driven equality assertion.
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# Portable timeout wrapper (macOS lacks `timeout`).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
