#!/bin/bash
# Tests: bin/github-issues/migration/orchestrate.sh
# Tags: migration, repo, github, issues, bin
# Tests for feat/migrate-repo — pre-flight existing-issues check in orchestrate.sh.
#
# Before Step 1, orchestrate.sh must detect whether the target repo already has
# issues via `gh issue list --state all --limit 1`.
#   - If issues exist in dry-run: print WARNING about early-number invariant.
#   - If issues exist in live mode and user answers "n": exit non-zero.
#   - If no issues exist: no WARNING.
#
# RED: fails clean while the pre-flight check is not yet implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/migration"

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
missing=()
[ -f "$ORCH_SCRIPT" ] || missing+=("bin/github-issues/migration/orchestrate.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixture builder: minimal repo + gh-mock on PATH.
# The mock supports MOCK_HAS_ISSUES=1 to simulate existing issues.
# ---------------------------------------------------------------------------
setup_fixture() {
    TMP="$(mktemp -d)"
    REPO="$TMP/repo"
    mkdir -p "$REPO/docs"
    cat > "$REPO/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF

    # gh mock from fixtures (supports MOCK_HAS_ISSUES).
    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    MOCK_COUNTER="$TMP/counter"
    echo 101 > "$MOCK_COUNTER"
    : > "$MOCK_LOG"

    export MOCK_LOG MOCK_COUNTER
    export PATH="$MOCK_DIR:$PATH"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG MOCK_COUNTER AGENTS_CONFIG_DIR MOCK_HAS_ISSUES
}

# ---------------------------------------------------------------------------
# PF1: --dry-run with no existing issues → output does NOT contain "WARNING"
#      about existing issues.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES

OUT_PF1=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
RC_PF1=$?

# Accept exit 0; check no WARNING about existing issues.
if [ "$RC_PF1" -eq 0 ] && ! echo "$OUT_PF1" | grep -qi "WARNING.*existing issues\|WARNING.*issue.*number\|WARNING.*early.number\|existing issues.*WARNING"; then
    pass "PF1: --dry-run no existing issues → no WARNING about existing issues"
else
    fail "PF1: rc=$RC_PF1 output contained unexpected WARNING or non-zero exit. out='$OUT_PF1'"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF2: --dry-run with existing issues (MOCK_HAS_ISSUES=1) → output contains
#      "WARNING" and references issue number 5.
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1

OUT_PF2=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
RC_PF2=$?

# Should exit 0 (dry-run just warns, does not abort).
# Output must contain WARNING and the existing issue number (5).
HAS_WARNING_PF2=$(echo "$OUT_PF2" | grep -ci "WARNING" 2>/dev/null) || HAS_WARNING_PF2=0
HAS_ISSUE5_PF2=$(echo "$OUT_PF2" | grep -c "5" 2>/dev/null) || HAS_ISSUE5_PF2=0
if [ "$HAS_WARNING_PF2" -gt 0 ] && [ "$HAS_ISSUE5_PF2" -gt 0 ]; then
    pass "PF2: --dry-run with existing issues → WARNING shown, issue 5 referenced"
else
    fail "PF2: rc=$RC_PF2 has_warning=$HAS_WARNING_PF2 has_issue5=$HAS_ISSUE5_PF2 (expected WARNING + issue 5 in output)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF3: Live mode (not dry-run) with existing issues, user answers "n" →
#      orchestrate.sh exits non-zero AND the abort must happen BEFORE Step 1
#      (the pre-flight check runs before any steps).
#      In RED phase: there is no pre-flight prompt, so "n" is consumed by the
#      first canary confirm inside Step 2; the output will contain "Step 1"
#      (label sync), which means the pre-flight check is NOT yet implemented.
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1

OUT_PF3=$(echo "n" | run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" 2>&1)
RC_PF3=$?

# The preflight check must abort BEFORE Step 1:
# - exit non-zero
# - output contains WARNING about existing issues (the pre-flight prompt)
# - output does NOT contain "Step 1:" (aborted before reaching it)
PRE_STEP1=$(echo "$OUT_PF3" | grep -c "Step 1:" 2>/dev/null) || PRE_STEP1=0
HAS_WARNING=$(echo "$OUT_PF3" | grep -ci "WARNING" 2>/dev/null) || HAS_WARNING=0

if [ "$RC_PF3" -ne 0 ] && [ "$HAS_WARNING" -gt 0 ] && [ "$PRE_STEP1" = "0" ]; then
    pass "PF3: live mode + existing issues + user='n' → WARNING shown, abort before Step 1"
else
    fail "PF3: rc=$RC_PF3 has_warning=$HAS_WARNING pre_step1_in_output=$PRE_STEP1 (expected non-zero exit with WARNING, no Step 1 in output)"
fi
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
