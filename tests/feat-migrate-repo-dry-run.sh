#!/bin/bash
# Tests for feat/migrate-repo — orchestrate.sh --dry-run
#
# Dry-run must:
#   - Exit 0
#   - Create no state file, no .github/, no commits
#   - Never invoke gh (mock exits 99 if called)
#   - Print Step 3 ordering gate as SKIPPED
#
# RED: fails clean while orchestrate.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"

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

    # Strict gh-mock: any invocation exits 99 (should never be called in dry-run).
    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/bash
echo "gh called: $*" >> "${MOCK_LOG:-/dev/null}"
exit 99
EOF
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export MOCK_LOG
    export PATH="$MOCK_DIR:$PATH"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG AGENTS_CONFIG_DIR
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

# --- D5: gh never called
if [ ! -s "$MOCK_LOG" ]; then
    pass "D5: gh mock never invoked"
else
    fail "D5: gh was called: $(cat "$MOCK_LOG")"
fi

teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
