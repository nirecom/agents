#!/bin/bash
# Tests: bin/github-issues/migration/orchestrate.sh
# Tags: migration, repo, github, issues, bin, scope:issue-specific
# Tests for feat/migrate-repo — pre-flight existing-issues check in orchestrate.sh.
# Before any state mutation it detects existing issues (`gh issue list --state all --limit 1`):
#   - Dry-run + existing issues: WARNING about the early-number invariant; continue.
#   - Live + existing issues, NO MIGRATE_ACK_EXISTING_ISSUES=1: WARNING + ERROR with the
#     re-run hint, exit 1 BEFORE Step 1. The ack gate is an AskUserQuestion in the
#     migrate-repo skill (#679); no stdin read, so `yes y |` cannot bypass it (#415).
#   - Live + existing issues + ack: WARNING + "acknowledged by caller"; continue into Step 1.
#   - No existing issues: no WARNING; proceed.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/migration"

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
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_ISSUES
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
# PF3: Live mode + existing issues + NO MIGRATE_ACK_EXISTING_ISSUES env var →
#      orchestrate.sh must print WARNING + ERROR with the
#      MIGRATE_ACK_EXISTING_ISSUES=1 re-run hint, then exit 1 BEFORE Step 1
#      (the env-var gate is tty-bypass-resistant; no stdin read).
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_EXISTING_ISSUES

OUT_PF3=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" 2>&1)
RC_PF3=$?

# Expected: WARNING + ERROR + env-var hint + Step 1 NOT reached + rc != 0
HAS_WARNING_PF3=$(echo "$OUT_PF3" | grep -ci "WARNING" 2>/dev/null) || HAS_WARNING_PF3=0
HAS_ERROR_PF3=$(echo "$OUT_PF3" | grep -c "ERROR" 2>/dev/null) || HAS_ERROR_PF3=0
HAS_HINT_PF3=$(echo "$OUT_PF3" | grep -c "MIGRATE_ACK_EXISTING_ISSUES=1" 2>/dev/null) || HAS_HINT_PF3=0
STEP1_PF3=$(echo "$OUT_PF3" | grep -c "Step 1:" 2>/dev/null) || STEP1_PF3=0

if [ "$HAS_WARNING_PF3" -gt 0 ] && [ "$HAS_ERROR_PF3" -gt 0 ] && [ "$HAS_HINT_PF3" -gt 0 ] && [ "$STEP1_PF3" -eq 0 ] && [ "$RC_PF3" -ne 0 ]; then
    pass "PF3: live + existing + no-ack → WARNING + ERROR + env-var hint, Step 1 NOT reached, rc=$RC_PF3"
else
    fail "PF3: has_warning=$HAS_WARNING_PF3 has_error=$HAS_ERROR_PF3 has_hint=$HAS_HINT_PF3 step1=$STEP1_PF3 rc=$RC_PF3 (expected WARNING + ERROR + MIGRATE_ACK_EXISTING_ISSUES=1 hint, Step 1 NOT reached, rc!=0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF4: Live mode + existing issues + MIGRATE_ACK_EXISTING_ISSUES=1 →
#      orchestrate.sh must print WARNING + "acknowledged by caller" message,
#      continue past pre-flight into Step 1, then hit the expected
#      Step 2 `--stage required` gate (rc != 0 by design).
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1
export MIGRATE_ACK_UP_TO_ISSUE_N=5
export MIGRATE_ACK_SELF_COUNT_AT_ACK=0
export MIGRATE_ACK_EXISTING_ISSUES=1

OUT_PF4=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" 2>&1)
RC_PF4=$?

HAS_WARNING_PF4=$(echo "$OUT_PF4" | grep -ci "WARNING" 2>/dev/null) || HAS_WARNING_PF4=0
HAS_ACK_PF4=$(echo "$OUT_PF4" | grep -c "acknowledged" 2>/dev/null) || HAS_ACK_PF4=0
STEP1_PF4=$(echo "$OUT_PF4" | grep -c "Step 1:" 2>/dev/null) || STEP1_PF4=0
STAGE_GATE_PF4=$(echo "$OUT_PF4" | grep -c "Step 2 (history migration) requires --stage" 2>/dev/null) || STAGE_GATE_PF4=0

if [ "$HAS_WARNING_PF4" -gt 0 ] && [ "$HAS_ACK_PF4" -gt 0 ] && [ "$STEP1_PF4" -gt 0 ] && [ "$STAGE_GATE_PF4" -gt 0 ] && [ "$RC_PF4" -ne 0 ]; then
    pass "PF4: live + existing + ack=1 → WARNING + ack msg, Step 1 reached, Step 2 --stage gate hit (rc=$RC_PF4)"
else
    fail "PF4: has_warning=$HAS_WARNING_PF4 has_ack=$HAS_ACK_PF4 step1=$STEP1_PF4 stage_gate=$STAGE_GATE_PF4 rc=$RC_PF4 (expected WARNING + ack msg + Step 1 + Step 2 --stage gate + rc!=0)"
fi
unset MIGRATE_ACK_EXISTING_ISSUES
unset MIGRATE_ACK_UP_TO_ISSUE_N
unset MIGRATE_ACK_SELF_COUNT_AT_ACK
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
