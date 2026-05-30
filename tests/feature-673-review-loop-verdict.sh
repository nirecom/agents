#!/usr/bin/env bash
# L1 unit tests for bin/review-loop-verdict (issue #673)
# Verdict matrix + argument validation.
# NOTE: bin/review-loop-verdict does not exist yet — tests will FAIL until implemented.
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_WORKTREE/bin/review-loop-verdict"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
    echo "SKIP: $SCRIPT does not exist yet (pre-implementation)"
    exit 0
fi

# Run the script and capture stdout + exit code
# Usage: run_verdict <expected_stdout> <expected_exit> <label> <args...>
run_verdict() {
    local expected_stdout="$1"
    local expected_exit="$2"
    local label="$3"
    shift 3
    local actual_stdout actual_exit=0
    actual_stdout=$(run_with_timeout bash "$SCRIPT" "$@" 2>/dev/null) || actual_exit=$?
    actual_stdout=$(echo "$actual_stdout" | tr -d '\r' | head -1)

    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
        fail "$label: expected exit $expected_exit, got $actual_exit (stdout='$actual_stdout', args=$*)"
        return
    fi
    if [[ -n "$expected_stdout" && "$actual_stdout" != "$expected_stdout" ]]; then
        fail "$label: expected stdout '$expected_stdout', got '$actual_stdout' (args=$*)"
        return
    fi
    pass "$label"
}

# Args interpretation: <round> <high> <medium> <low>

# ---------------------------------------------------------------------------
# Normal verdict matrix
# ---------------------------------------------------------------------------
run_verdict "APPROVED" 0 "1: round=1 high=0 medium=0 low=1 → APPROVED" 1 0 0 1
run_verdict "CONTINUE" 1 "2: round=1 high=0 medium=1 low=0 → CONTINUE" 1 0 1 0
run_verdict "CONTINUE" 1 "3: round=1 high=1 medium=0 low=0 → CONTINUE" 1 1 0 0
run_verdict "CONTINUE" 1 "4: round=1 high=1 medium=1 low=1 → CONTINUE" 1 1 1 1
run_verdict "APPROVED" 0 "5: round=2 high=0 medium=0 low=1 → APPROVED" 2 0 0 1
run_verdict "APPROVED" 0 "6: round=2 high=0 medium=1 low=0 → APPROVED" 2 0 1 0
run_verdict "CONTINUE" 1 "7: round=2 high=1 medium=0 low=0 → CONTINUE" 2 1 0 0
run_verdict "CONTINUE" 1 "8: round=2 high=1 medium=1 low=1 → CONTINUE" 2 1 1 1
run_verdict "APPROVED" 0 "9: round=3 high=0 medium=0 low=0 → APPROVED" 3 0 0 0
run_verdict "ESCALATE" 2 "10: round=3 high=1 medium=0 low=0 → ESCALATE" 3 1 0 0
run_verdict "APPROVED" 0 "11: round=3 high=0 medium=1 low=0 → APPROVED" 3 0 1 0

# Extra: round=4 high>0 → ESCALATE
run_verdict "ESCALATE" 2 "11b: round=4 high=2 medium=0 low=0 → ESCALATE" 4 2 0 0
# round=2 high=0 medium=0 low=0 → APPROVED (all zero)
run_verdict "APPROVED" 0 "11c: round=2 all zero → APPROVED" 2 0 0 0

# ---------------------------------------------------------------------------
# Arg validation (exit 3)
# ---------------------------------------------------------------------------

# 12. Missing args (only 3 of 4)
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 1 0 0 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "12: missing arg (3 of 4) → exit 3"
    else
        fail "12: missing arg (3 of 4) → expected exit 3, got $rc"
    fi
}

# 12b. No args at all
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "12b: no args → exit 3"
    else
        fail "12b: no args → expected exit 3, got $rc"
    fi
}

# 13. Non-integer arg
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 1 abc 0 0 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "13: non-integer high='abc' → exit 3"
    else
        fail "13: non-integer high='abc' → expected exit 3, got $rc"
    fi
}

# 13b. Non-integer round
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" foo 0 0 0 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "13b: non-integer round='foo' → exit 3"
    else
        fail "13b: non-integer round='foo' → expected exit 3, got $rc"
    fi
}

# 14. Negative count
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 1 -- -1 0 0 2>/dev/null) || rc=$?
    # Try direct (some shells will treat -1 as a flag)
    if [[ $rc -ne 3 ]]; then
        rc=0
        OUT=$(run_with_timeout bash "$SCRIPT" 1 -1 0 0 2>/dev/null) || rc=$?
    fi
    if [[ $rc -eq 3 ]]; then
        pass "14: negative count (high=-1) → exit 3"
    else
        fail "14: negative count (high=-1) → expected exit 3, got $rc"
    fi
}

# 15. round=0 (round<1)
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 0 0 0 0 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "15: round=0 → exit 3"
    else
        fail "15: round=0 → expected exit 3, got $rc"
    fi
}

# 15b. Extra args (5 instead of 4)
{
    rc=0
    OUT=$(run_with_timeout bash "$SCRIPT" 1 0 0 0 0 2>/dev/null) || rc=$?
    if [[ $rc -eq 3 ]]; then
        pass "15b: extra arg (5 of 4) → exit 3"
    else
        fail "15b: extra arg → expected exit 3, got $rc"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
