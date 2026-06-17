#!/usr/bin/env bash
# Tests: .env.example, tests/feature-robust-workflow.sh, tests/feature-644-agent-delegation/phase5-main-transcript-no-delegated-output.sh
# Tags: env-example, e2e-toggle, run-e2e
# Tests for issue #941 — migrate RUN_E2E from ad-hoc env var to .env-keyed toggle.
#
# Test-first (TDD): the implementation has not yet been applied — these tests
# are expected to FAIL initially (RED state). After implementation:
#   1. .env.example gains a RUN_E2E entry
#   2. feature-robust-workflow.sh guard migrates to bin/get-config-var --is-off
#   3. phase5-main-transcript-no-delegated-output.sh adds a RUN_E2E guard
# all six cases must PASS.
#
# L3 gap (what this test does NOT catch):
# - Actual claude -p invocation when RUN_E2E=on (requires real Anthropic API + billing)
# - feature-robust-workflow.sh E1 block execution end-to-end (heavy test suite, not run here)
# Closest-to-action mitigation: static guard-pattern check covers the migration correctness

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="$AGENTS_DIR/.env.example"
ROBUST_WF="$AGENTS_DIR/tests/feature-robust-workflow.sh"
PHASE5_SCRIPT="$AGENTS_DIR/tests/feature-644-agent-delegation/phase5-main-transcript-no-delegated-output.sh"
GET_CONFIG_VAR="$AGENTS_DIR/bin/get-config-var"
REVIEW_ENV_EXAMPLE="$AGENTS_DIR/bin/review-env-example"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# Stage a stub `claude` on PATH so case 3 can pass the `command -v claude` guard
# without actually invoking the real CLI. The stub exits 77 immediately so that
# any downstream claude -p call also produces SKIP (treated as "guard passed but
# real execution skipped"), and we assert exit != 77 only when the FEATURE_644
# and RUN_E2E guards together let the script reach the claude check.
STUB_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/feature-941-stub-$$")"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub claude — succeeds immediately so the guard-pass test sees a non-skip exit.
# Emits a minimal JSON envelope to stdout so jq parsing in the script does not blow up.
echo '{"messages":[{"role":"assistant","content":[{"type":"text","text":"hello world"}]}]}'
exit 0
STUB_EOF
chmod +x "$STUB_DIR/claude"
trap 'rm -rf "$STUB_DIR"' EXIT

# ============================================================================
# Case 1 — .env.example contains a RUN_E2E entry and passes review-env-example
# ============================================================================
echo "=== Case 1: .env.example RUN_E2E entry ==="

if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "1. .env.example not found at $ENV_EXAMPLE"
else
    if grep -qE '^[[:space:]]*RUN_E2E=' "$ENV_EXAMPLE"; then
        pass "1a. RUN_E2E entry present in .env.example"
    else
        fail "1a. RUN_E2E entry missing from .env.example"
    fi

    if [ -x "$REVIEW_ENV_EXAMPLE" ]; then
        if run_with_timeout 60 bash "$REVIEW_ENV_EXAMPLE" --all >/tmp/941-rev.out 2>&1; then
            # --all always exits 0; assert no HARD findings reported
            if grep -qE '\bHARD\b.*finding' /tmp/941-rev.out && ! grep -qE 'Review: 0 findings' /tmp/941-rev.out; then
                fail "1b. review-env-example --all reports HARD findings"
                sed 's/^/  | /' /tmp/941-rev.out
            else
                pass "1b. review-env-example --all reports no HARD findings"
            fi
        else
            fail "1b. review-env-example --all failed unexpectedly"
            sed 's/^/  | /' /tmp/941-rev.out
        fi
        rm -f /tmp/941-rev.out
    else
        fail "1b. review-env-example binary not executable"
    fi
fi

# ============================================================================
# Case 2 — phase5 script with FEATURE_644_PHASE=5 + RUN_E2E=off exits 77
# ============================================================================
echo "=== Case 2: phase5 + RUN_E2E=off ==="

if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "2. phase5 script not found"
else
    # Ensure stub claude is on PATH so the `command -v claude` guard is not what skips us
    set +e
    PATH="$STUB_DIR:$PATH" FEATURE_644_PHASE=5 RUN_E2E=off \
        run_with_timeout 30 bash "$PHASE5_SCRIPT" >/tmp/941-c2.out 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 77 ]; then
        if grep -qiE 'RUN_E2E' /tmp/941-c2.out; then
            pass "2. exit 77 with RUN_E2E-related SKIP message"
        else
            pass "2. exit 77 (RUN_E2E=off honoured; SKIP message may differ)"
        fi
    else
        fail "2. expected exit 77 with RUN_E2E=off, got $rc"
        sed 's/^/  | /' /tmp/941-c2.out
    fi
    rm -f /tmp/941-c2.out
fi

# ============================================================================
# Case 3 — phase5 script with FEATURE_644_PHASE=5 + RUN_E2E=on passes guards
# ============================================================================
echo "=== Case 3: phase5 + RUN_E2E=on (guards pass) ==="

if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "3. phase5 script not found"
else
    set +e
    PATH="$STUB_DIR:$PATH" FEATURE_644_PHASE=5 RUN_E2E=on \
        run_with_timeout 60 bash "$PHASE5_SCRIPT" >/tmp/941-c3.out 2>&1
    rc=$?
    set -e
    # With both guards passed, the script must NOT exit 77 due to RUN_E2E or FEATURE_644 guards.
    # It may still SKIP for downstream reasons (timeout, parse failure) — those skips emit
    # SKIP messages mentioning claude/response/parse, not the RUN_E2E/FEATURE guards.
    if [ "$rc" -eq 77 ]; then
        if grep -qiE 'requires RUN_E2E|requires FEATURE_644_PHASE' /tmp/941-c3.out; then
            fail "3. RUN_E2E=on still tripped the RUN_E2E/FEATURE guard (rc=77)"
            sed 's/^/  | /' /tmp/941-c3.out
        else
            pass "3. RUN_E2E/FEATURE guards passed (later SKIP from downstream cause)"
        fi
    else
        pass "3. guards passed and script proceeded (rc=$rc)"
    fi
    rm -f /tmp/941-c3.out
fi

# ============================================================================
# Case 4 — FEATURE_644_PHASE=4 + RUN_E2E=on → FEATURE gate fires first (exit 77)
# ============================================================================
echo "=== Case 4: FEATURE_644_PHASE=4 + RUN_E2E=on ==="

if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "4. phase5 script not found"
else
    set +e
    PATH="$STUB_DIR:$PATH" FEATURE_644_PHASE=4 RUN_E2E=on \
        run_with_timeout 30 bash "$PHASE5_SCRIPT" >/tmp/941-c4.out 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 77 ] && grep -qiE 'FEATURE_644_PHASE' /tmp/941-c4.out; then
        pass "4. FEATURE_644 gate fires first (exit 77)"
    else
        fail "4. expected exit 77 with FEATURE_644_PHASE message, got rc=$rc"
        sed 's/^/  | /' /tmp/941-c4.out
    fi
    rm -f /tmp/941-c4.out
fi

# ============================================================================
# Case 5 — RUN_E2E=0 is treated as off (exit 77)
# ============================================================================
echo "=== Case 5: RUN_E2E=0 treated as off ==="

if [ ! -f "$PHASE5_SCRIPT" ]; then
    fail "5. phase5 script not found"
else
    set +e
    PATH="$STUB_DIR:$PATH" FEATURE_644_PHASE=5 RUN_E2E=0 \
        run_with_timeout 30 bash "$PHASE5_SCRIPT" >/tmp/941-c5.out 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 77 ]; then
        pass "5. RUN_E2E=0 → exit 77 (treated as off)"
    else
        fail "5. expected exit 77 with RUN_E2E=0, got $rc"
        sed 's/^/  | /' /tmp/941-c5.out
    fi
    rm -f /tmp/941-c5.out
fi

# ============================================================================
# Case 6 — Static check: feature-robust-workflow.sh migrated guard
# ============================================================================
echo "=== Case 6: feature-robust-workflow.sh guard migration ==="

if [ ! -f "$ROBUST_WF" ]; then
    fail "6. feature-robust-workflow.sh not found"
else
    # New pattern: get-config-var --is-off RUN_E2E
    if grep -qE 'get-config-var[^|]*--is-off[[:space:]]+RUN_E2E' "$ROBUST_WF"; then
        pass "6a. new guard pattern (get-config-var --is-off RUN_E2E) present"
    else
        fail "6a. new guard pattern (get-config-var --is-off RUN_E2E) missing"
    fi

    # Old pattern: ${RUN_E2E:-0} should be gone
    if grep -qE '\$\{RUN_E2E:-0\}' "$ROBUST_WF"; then
        fail "6b. legacy guard pattern (\${RUN_E2E:-0}) still present"
    else
        pass "6b. legacy guard pattern (\${RUN_E2E:-0}) removed"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
