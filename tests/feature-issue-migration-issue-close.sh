#!/bin/bash
# Tests for bin/github-issues/issue-to-history.sh — issue-close path that converts a closed
# GitHub issue into a docs/history.md entry.
#
# RED: this suite fails clean while bin/github-issues/issue-to-history.sh does not exist yet.
# GREEN: once the implementation lands, every test below should pass.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
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

# --- Existence gate (RED while implementation is missing) -------------------
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/issue-to-history.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

if [ ! -x "$MOCK_DIR/gh" ]; then
    chmod +x "$MOCK_DIR/gh" 2>/dev/null || true
fi
if [ ! -x "$MOCK_DIR/doc-append" ]; then
    chmod +x "$MOCK_DIR/doc-append" 2>/dev/null || true
fi

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
}

# --- N1: type:task → FEATURE entry with #42: ---
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "#42:" "$TMP/docs/history.md" && grep -q "FEATURE" "$TMP/docs/history.md"; then
    pass "N1: type:task label produces FEATURE entry"
else
    fail "N1: type:task label produces FEATURE entry"
fi
teardown_tmp

# --- N2: type:incident → INCIDENT entry ---
setup_tmp
GH_MOCK_SCENARIO=issue_incident run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "INCIDENT" "$TMP/docs/history.md"; then
    pass "N2: type:incident label produces INCIDENT entry"
else
    fail "N2: type:incident label produces INCIDENT entry"
fi
teardown_tmp

# --- N3: no labels → FEATURE (default) ---
setup_tmp
GH_MOCK_SCENARIO=issue_no_labels run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "FEATURE" "$TMP/docs/history.md"; then
    pass "N3: no labels defaults to FEATURE"
else
    fail "N3: no labels defaults to FEATURE"
fi
teardown_tmp

# --- N4: --commit abc1234 → commit hash in entry ---
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 --commit abc1234 >/dev/null 2>&1
if grep -q "abc1234" "$TMP/docs/history.md"; then
    pass "N4: --commit hash appears in entry"
else
    fail "N4: --commit hash appears in entry"
fi
teardown_tmp

# --- I1: idempotency — second run does not duplicate ---
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
COUNT=$(grep -c "#42:" "$TMP/docs/history.md" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$COUNT" -eq 1 ]; then
    pass "I1: re-run is idempotent (single #42: entry)"
else
    fail "I1: re-run is idempotent (rc=$RC count=$COUNT)"
fi
teardown_tmp

# --- I2: entry already in rotated archive ---
setup_tmp
echo "### #42: Old archived entry (2025-01-01)" > "$TMP/docs/history/2025.md"
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
NEW_COUNT=$(grep -c "#42:" "$TMP/docs/history.md" 2>/dev/null; true)
if [ "$RC" -eq 0 ] && [ "$NEW_COUNT" -eq 0 ]; then
    pass "I2: rotated archive entry suppresses re-append"
else
    fail "I2: rotated archive entry suppresses re-append (rc=$RC new=$NEW_COUNT)"
fi
teardown_tmp

# --- E1: no args → non-zero exit + stderr ---
setup_tmp
ERR=$(GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ] && [ -n "$ERR" ]; then
    pass "E1: no args fails with diagnostic"
else
    fail "E1: no args fails with diagnostic (rc=$RC)"
fi
teardown_tmp

# --- E2: AGENTS_CONFIG_DIR unset → non-zero exit ---
setup_tmp
unset AGENTS_CONFIG_DIR
ERR=$(GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 2>&1 >/dev/null)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "E2: missing AGENTS_CONFIG_DIR fails"
else
    fail "E2: missing AGENTS_CONFIG_DIR fails (rc=$RC)"
fi
teardown_tmp

# --- E3: gh issue view returns exit 1 → script fails ---
setup_tmp
GH_MOCK_SCENARIO=issue_view_fail run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "E3: gh failure propagates"
else
    fail "E3: gh failure propagates (rc=$RC)"
fi
teardown_tmp

# --- S1: shell-injection style issue number is handled safely ---
setup_tmp
INJECTED_FILE="$TMP/INJECTED.flag"
# If the implementation passes "$1" through eval/sh -c, the side-effect file
# would appear. A safe implementation never executes the embedded `echo`.
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" "42; touch $INJECTED_FILE" >/dev/null 2>&1
RC=$?
if [ ! -f "$INJECTED_FILE" ] && [ "$RC" -ne 0 ]; then
    pass "S1: shell-injected issue number is rejected, no side effect"
else
    fail "S1: shell-injected issue number was NOT contained (rc=$RC injected=$([ -f "$INJECTED_FILE" ] && echo yes || echo no))"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
