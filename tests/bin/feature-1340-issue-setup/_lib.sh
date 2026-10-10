#!/bin/bash
# tests/bin/feature-1340-issue-setup/_lib.sh — shared scaffolding
# Sourced by each of the 7 split files (via a BASH_SOURCE-relative path) so they
# can also run standalone. Provides: __LIB_SCRIPT_CHECKOUT_ROOT, PASS / FAIL
# counters and pass / fail helpers, assert_eq (table-driven equality),
# run_with_timeout, get_field (KEY=value from a RESOLVED_*/EPR_* block).
# Each split file keeps its OWN gh mock factory, setup_mock/teardown_mock and env
# knobs — those differ per source-under-test and are intentionally NOT shared.
# NOT a test file: no # Tests:/# Tags: frontmatter; excluded from the
# dispatcher's SPLIT_GROUPS. Idempotent — guarded against repeated sourcing.

if [ -n "${_FEATURE_1340_LIB_SOURCED:-}" ]; then
    return 0
fi
_FEATURE_1340_LIB_SOURCED=1

set -u

# Repo root, resolved relative to this lib (tests/bin/feature-1340-issue-setup/).
__LIB_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Table-driven equality assertion (per test-design/parser-regex-tests.md §Table-Driven Tests).
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

# Extract a `KEY=value` field from a resolver/ensure round-trip stdout block.
get_field() {
    local out="$1" key="$2"
    printf '%s\n' "$out" | grep -E "^${key}=" | head -1 | cut -d= -f2-
}
