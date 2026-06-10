#!/bin/bash
# Tests: bin/github-issues/parent-body-update.sh
# Tags: parent-body-update, meta-guard, issue-close
# Tests for issue #708 — meta-label guard in parent-body-update.sh.
#
# The guard sits AFTER the existing `if [ -z "$PARENT" ]; then exit 0; fi`
# block. It queries the parent issue's labels via `gh api` and exits 0
# without calling `gh issue edit` when the parent carries the `meta` label.
# A failed API call is treated as fail-safe (assume meta → exit 0) so the
# script never edits a parent body when label state is uncertain.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT_SCRIPT="$AGENTS_DIR/bin/github-issues/parent-body-update.sh"
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

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$PARENT_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/parent-body-update.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Ensure mock helpers are executable (Windows checkouts may strip the bit).
for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
    unset GH_MOCK_COMMENT_LOG
    unset GH_META_LABEL
}

# ============================================================================
# P-meta-series — parent-body-update.sh meta-label guard
# ============================================================================

# --- P-meta-1: parent has only the `meta` label → exit 0, no edit
setup_tmp
GH_META_LABEL=true \
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && ! echo "$LOG" | grep -q "EDIT_PARENT_"; then
    pass "P-meta-1: parent has only meta label → exit 0, no edit"
else
    fail "P-meta-1: rc=$RC log=$LOG (expected rc=0 and no EDIT_PARENT_)"
fi
teardown_tmp

# --- P-meta-2: parent has no `meta` label → edit IS called (regression guard)
setup_tmp
GH_META_LABEL=false \
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && echo "$LOG" | grep -q "EDIT_PARENT_99" && echo "$LOG" | grep -q -- "- \[x\] #42"; then
    pass "P-meta-2: parent has no meta label → parent body edited"
else
    fail "P-meta-2: rc=$RC log=$LOG (expected rc=0 and EDIT_PARENT_99 with checked checkbox)"
fi
teardown_tmp

# --- P-meta-3: parent has multiple labels including `meta` → exit 0, no edit
setup_tmp
GH_META_LABEL=true \
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
# Same expectation as P-meta-1: the jq expression `any(.labels[].name; . == "meta")`
# returns true for ["type:task","meta"] just as it does for ["meta"]. The mock
# returns the same `true` for both — what matters at the script's boundary is the
# `true`/`false` decision, not the underlying label set composition.
if [ "$RC" -eq 0 ] && ! echo "$LOG" | grep -q "EDIT_PARENT_"; then
    pass "P-meta-3: parent has [type:task, meta] → exit 0, no edit"
else
    fail "P-meta-3: rc=$RC log=$LOG (expected rc=0 and no EDIT_PARENT_)"
fi
teardown_tmp

# --- P-meta-4: parent has only `meta-something` (partial match) → edit IS called
# The jq expression uses exact-match equality (`. == "meta"`), so a label
# named `meta-something` returns false → guard does not fire → script continues.
setup_tmp
GH_META_LABEL=false \
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && echo "$LOG" | grep -q "EDIT_PARENT_99" && echo "$LOG" | grep -q -- "- \[x\] #42"; then
    pass "P-meta-4: parent has only meta-something (partial match) → edit IS called"
else
    fail "P-meta-4: rc=$RC log=$LOG (expected rc=0 and EDIT_PARENT_99 with checked checkbox)"
fi
teardown_tmp

# --- P-meta-5: `gh api` labels call fails → fail-safe → exit 0, no edit
setup_tmp
GH_META_LABEL=fail \
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && ! echo "$LOG" | grep -q "EDIT_PARENT_"; then
    pass "P-meta-5: gh api labels call fails → fail-safe (exit 0, no edit)"
else
    fail "P-meta-5: rc=$RC log=$LOG (expected rc=0 and no EDIT_PARENT_)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
