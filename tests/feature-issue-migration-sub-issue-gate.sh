#!/bin/bash
# Tests for bin/issue-close-gate.sh — gate that blocks issue closure when
# any sub-issue is still open.
#
# RED: this suite fails clean while bin/issue-close-gate.sh does not exist yet.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/issue-close-gate.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/issue-close-gate.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

if [ ! -x "$MOCK_DIR/gh" ]; then
    chmod +x "$MOCK_DIR/gh" 2>/dev/null || true
fi

export PATH="$MOCK_DIR:$PATH"

# --- N1: no sub-issues → exit 0 ---
GH_MOCK_SCENARIO=no_subissues run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "N1: zero sub-issues → exit 0"
else
    fail "N1: zero sub-issues → exit 0 (rc=$RC)"
fi

# --- N2: all closed sub-issues → exit 0 ---
GH_MOCK_SCENARIO=all_closed_subissues run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "N2: all-closed sub-issues → exit 0"
else
    fail "N2: all-closed sub-issues → exit 0 (rc=$RC)"
fi

# --- N3: 1 open sub-issue → exit 1, stderr names issue ---
ERR=$(GH_MOCK_SCENARIO=one_open_subissue run_with_timeout 30 bash "$TARGET" owner/repo 10 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ] && echo "$ERR" | grep -qE "11|Open child"; then
    pass "N3: one open sub-issue → fail with detail"
else
    fail "N3: one open sub-issue → fail with detail (rc=$RC stderr=$ERR)"
fi

# --- N4: 3 open sub-issues → exit 1, lists all 3 ---
ERR=$(GH_MOCK_SCENARIO=three_open_subissues run_with_timeout 30 bash "$TARGET" owner/repo 10 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "N4: three open sub-issues → exit non-zero"
else
    fail "N4: three open sub-issues → exit non-zero (rc=$RC)"
fi

# --- E1: paginated, 1 open → exit 1 ---
GH_MOCK_SCENARIO=paginated_one_open run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "E1: paginated with one open → fail"
else
    fail "E1: paginated with one open → fail (rc=$RC)"
fi

# --- E2: paginated, all closed → exit 0 ---
GH_MOCK_SCENARIO=paginated_all_closed run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "E2: paginated all-closed → exit 0"
else
    fail "E2: paginated all-closed → exit 0 (rc=$RC)"
fi

# --- E3: status:cancelled / status:migrated AND closed → exit 0 ---
GH_MOCK_SCENARIO=all_cancelled_or_migrated run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "E3: cancelled/migrated children → exit 0"
else
    fail "E3: cancelled/migrated children → exit 0 (rc=$RC)"
fi

# --- R1: missing args → non-zero + usage ---
ERR=$(run_with_timeout 30 bash "$TARGET" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ] && [ -n "$ERR" ]; then
    pass "R1: missing args → usage diagnostic"
else
    fail "R1: missing args → usage diagnostic (rc=$RC)"
fi

# --- R2: gh api fails → non-zero ---
GH_MOCK_SCENARIO=api_fail run_with_timeout 30 bash "$TARGET" owner/repo 10 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "R2: gh api failure propagates"
else
    fail "R2: gh api failure propagates (rc=$RC)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
