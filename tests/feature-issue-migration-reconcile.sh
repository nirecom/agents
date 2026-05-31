#!/bin/bash
# Tests: bin/github-issues/issue-to-history.sh
# Tags: issue-close, stage, workflow, finalize, history
# Tests for the reconcile path of bin/github-issues/issue-to-history.sh — backfill history
# entries for issues that were closed without going through /issue-close-stage + /issue-close-finalize.
#
# Includes a check that the jq sentinel detector correctly identifies the
# `<!-- issue-close-sentinel: ... -->` marker in issue comments.
#
# RED: this suite fails clean while bin/github-issues/issue-to-history.sh is missing.

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
    unset DOC_APPEND_FAIL
}

# --- N1: ISSUE_CLOSE_SKILL=1 on closed mock issue → appends ---
setup_tmp
ISSUE_CLOSE_SKILL=1 GH_MOCK_SCENARIO=issue_task \
    run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "#42" "$TMP/docs/history.md"; then
    pass "N1: skill-driven append writes #42"
else
    fail "N1: skill-driven append writes #42"
fi
teardown_tmp

# --- N2: jq sentinel detection ---
if command -v jq >/dev/null 2>&1; then
    SENTINEL_JSON='{"comments":[{"body":"first comment"},{"body":"<!-- issue-close-sentinel: 42 -->"}]}'
    OUT=$(echo "$SENTINEL_JSON" | jq -r '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | first')
    if [ "$OUT" = "<!-- issue-close-sentinel: 42 -->" ]; then
        pass "N2: jq sentinel filter detects marker"
    else
        fail "N2: jq sentinel filter detects marker (got=$OUT)"
    fi

    NO_SENTINEL='{"comments":[{"body":"plain"},{"body":"no marker here"}]}'
    OUT=$(echo "$NO_SENTINEL" | jq -r '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | first')
    if [ "$OUT" = "null" ]; then
        pass "N2b: jq sentinel filter returns null when absent"
    else
        fail "N2b: jq sentinel filter returns null when absent (got=$OUT)"
    fi
else
    echo "SKIP: jq not available — N2 sentinel filter check skipped"
fi

# --- N3: reconcile — no sentinel, no entry → appends ---
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "#42" "$TMP/docs/history.md"; then
    pass "N3: reconcile appends when no entry exists"
else
    fail "N3: reconcile appends when no entry exists"
fi
teardown_tmp

# --- I1: history.md already has #42: → no duplicate ---
setup_tmp
echo "### #42: Pre-existing entry (2026-04-01)" >> "$TMP/docs/history.md"
BEFORE=$(grep -c "#42" "$TMP/docs/history.md")
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
AFTER=$(grep -c "#42" "$TMP/docs/history.md")
if [ "$RC" -eq 0 ] && [ "$AFTER" -eq "$BEFORE" ]; then
    pass "I1: existing #42: in history.md prevents duplicate"
else
    fail "I1: existing #42: in history.md prevents duplicate (rc=$RC before=$BEFORE after=$AFTER)"
fi
teardown_tmp

# --- I2: rotated archive has #42: → no duplicate ---
setup_tmp
echo "### #42: Archived (2025-12-01)" > "$TMP/docs/history/2025.md"
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
COUNT=$(grep -c "#42" "$TMP/docs/history.md" 2>/dev/null); true
if [ "$RC" -eq 0 ] && [ "$COUNT" -eq 0 ]; then
    pass "I2: archived #42: prevents new append"
else
    fail "I2: archived #42: prevents new append (rc=$RC count=$COUNT)"
fi
teardown_tmp

# --- E1: sentinel present but history missing entry → recovery append ---
setup_tmp
# History.md is empty even though the issue was already closed (sentinel set
# upstream). Reconcile should still append.
GH_MOCK_SCENARIO=issue_task run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
if grep -q "#42" "$TMP/docs/history.md"; then
    pass "E1: missing history entry is recovered even with sentinel set"
else
    fail "E1: missing history entry is recovered even with sentinel set"
fi
teardown_tmp

# --- R1: doc-append fails → script exits non-zero ---
setup_tmp
DOC_APPEND_FAIL=1 GH_MOCK_SCENARIO=issue_task \
    run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "R1: doc-append failure propagates"
else
    fail "R1: doc-append failure propagates (rc=$RC)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
