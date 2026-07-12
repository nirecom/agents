#!/usr/bin/env bash
# tests/feature-437-compose-doc-append-idempotency.sh
# Tests: bin/compose-doc-append-entry
# Tags: scope:issue-specific
# Tests for issue #437 — compose-doc-append-entry idempotency guard.
#
# Two invocations with the same branch + PR number must not append twice:
# the first call stakes a per-branch/PR marker file; the second finds the
# marker and skips the history write entirely (WANT_HISTORY=0 → early exit).
#
# This exercises the EXISTING guard, so it PASSES against current source.
# We drive it in --dry-run so no real gh API call is made: dry-run still
# consults the marker and prints its intent only when a write would occur.
#
# L3 gap (what this test does NOT catch):
# - real GitHub API calls and actual issue state transitions
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$AGENTS_DIR/bin/compose-doc-append-entry"
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
if [ ! -f "$COMPOSE" ]; then
    echo "FAIL: precondition missing — bin/compose-doc-append-entry"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    mkdir -p "$WORKFLOW_PLANS_DIR"
    export PATH="$MOCK_DIR:$PATH"
    NOTES="$TMP/WORKTREE_NOTES.md"
    cat > "$NOTES" <<'EOF'
## History Notes
- fix(#437): idempotency guard prevents duplicate history append

## Changelog Notes
- (none)
EOF
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR WORKFLOW_PLANS_DIR
}

BRANCH="fix/fix-437-idempotency"
PR="437"
MERGE="abc1234def5678"

# ============================================================================
# T1: first call (dry-run) reports it WOULD append to docs/history.md
# ============================================================================
setup_tmp
OUT1=$(run_with_timeout 30 bash "$COMPOSE" \
    --notes "$NOTES" --branch "$BRANCH" --pr "$PR" --merge-commit "$MERGE" \
    --category BUGFIX --test-gap "no idempotency test" --history --dry-run 2>&1)
RC1=$?
if [ "$RC1" -eq 0 ] && echo "$OUT1" | grep -qi "would append to docs/history.md"; then
    pass "T1: first dry-run reports a pending history append"
else
    fail "T1: rc=$RC1 out='$OUT1'"
fi

# ============================================================================
# T2: after staking the marker, a second call is a no-op (no duplicate)
# ============================================================================
# Dry-run does not write the marker itself, so simulate the completed first
# write by creating the marker the real (non-dry) path would create, then
# confirm the guard suppresses the second append.
ENCODED_BRANCH="${BRANCH//\//%2F}"
MARKER="$WORKFLOW_PLANS_DIR/markers/${ENCODED_BRANCH}-pr${PR}-history"
mkdir -p "$WORKFLOW_PLANS_DIR/markers"
printf '%s\n%s\n' "$MERGE" "2026-07-12T00:00:00Z" > "$MARKER"

OUT2=$(run_with_timeout 30 bash "$COMPOSE" \
    --notes "$NOTES" --branch "$BRANCH" --pr "$PR" --merge-commit "$MERGE" \
    --category BUGFIX --test-gap "no idempotency test" --history --dry-run 2>&1)
RC2=$?
if [ "$RC2" -eq 0 ] && ! echo "$OUT2" | grep -qi "would append to docs/history.md"; then
    pass "T2: second call with marker present → no duplicate history append"
else
    fail "T2: rc=$RC2 out='$OUT2' (marker guard did not suppress the append)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
