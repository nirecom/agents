#!/bin/bash
# Tests: bin/github-issues/migration/orchestrate.sh
# Tags: migration, repo, github, issues, bin, scope:issue-specific
# Tests for feat/migrate-repo — orchestrate.sh --dry-run. Dry-run must:
#   - Exit 0
#   - Create no state file, no .github/, no commits
#   - Never invoke gh (mock exits 99 if called)
#   - Print Step 3 ordering gate as SKIPPED
# RED: fails clean while orchestrate.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh"

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

setup_fixture() {
    TMP="$(mktemp -d)"
    FIXTURE="$TMP/repo"
    mkdir -p "$FIXTURE/docs"
    cat > "$FIXTURE/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1

### Entry 2 (2024-01-02)
Background: test entry 2
Changes: change 2
EOF
    cat > "$FIXTURE/docs/todo.md" <<'EOF'
## Active Work

- task-001: do something
EOF

    # gh-mock for dry-run: log all calls, return sensible no-op values.
    # Destructive calls (issue create/close) must not appear in the log.
    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cp "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/migration/gh-mock.sh" "$MOCK_DIR/gh"
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export MOCK_LOG
    export PATH="$MOCK_DIR:$PATH"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG
}

# Run dry-run once and reuse the output across multiple assertions.
setup_fixture
OUT=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$FIXTURE" --dry-run 2>&1)
RC=$?

# --- D1: exits 0
if [ "$RC" -eq 0 ]; then
    pass "D1: orchestrate.sh --dry-run exits 0"
else
    fail "D1: rc=$RC out=$OUT"
fi

# --- D2: no state file
if [ ! -f "$FIXTURE/.migration-state.json" ]; then
    pass "D2: no .migration-state.json created"
else
    fail "D2: state file was created"
fi

# --- D3: no .github/
if [ ! -d "$FIXTURE/.github" ]; then
    pass "D3: no .github/ directory created"
else
    fail "D3: .github/ was created"
fi

# --- D4: Step 3 ordering gate message
if echo "$OUT" | grep -qi "Step 3 ordering gate.*SKIPPED"; then
    pass "D4: Step 3 ordering gate marked SKIPPED"
else
    fail "D4: missing 'Step 3 ordering gate: SKIPPED' in stdout"
fi

# --- D5: no destructive gh calls (issue create / issue close) in dry-run.
# Read-only calls (e.g. gh issue list for pre-flight) are permitted.
destructive=$(grep -E '^gh issue create|^gh issue close' "$MOCK_LOG" 2>/dev/null | wc -l | tr -d ' ')
if [ "$destructive" -eq 0 ]; then
    pass "D5: no destructive gh calls (create/close) in dry-run"
else
    fail "D5: gh called: $(grep -E '^gh issue create|^gh issue close' "$MOCK_LOG" | head -1)"
fi

# --- D6: the backfill step is shown with the repository handed over by flag (#2561).
BACKFILL_LINE="backfill-commit-comments.sh --target-checkout-root $(cd "$FIXTURE" && pwd)"
if printf '%s\n' "$OUT" | grep -qF -- "$BACKFILL_LINE"; then
    pass "D6: backfill step names the repository by --target-checkout-root"
else
    fail "D6: missing '$BACKFILL_LINE' in: $(printf '%s\n' "$OUT" | grep -F backfill-commit-comments)"
fi

teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
