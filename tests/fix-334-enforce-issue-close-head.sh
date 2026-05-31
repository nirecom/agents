#!/bin/bash
# Tests: hooks/enforce-issue-close.js
# Tags: 334, enforce-issue-close-head
# Integration tests for issue #334 — enforce-issue-close.js head detection.
#
# After migrating enforce-issue-close.js to hasCommandHead(), the hook must:
#   1. Continue to block bare `gh issue close` and its segment-separator /
#      launcher-recursion variants.
#   2. NOT match `gh issue close` text appearing inside argument values
#      (e.g. inside --body of `gh issue comment`, inside `echo` argument).
#   3. Preserve the ISSUE_CLOSE_SKILL=1 env bypass and the
#      `ISSUE_CLOSE_SKILL=1 gh issue close ...` inline-shape bypass.
#
# RED stage: some of these false-positive prevention cases may fail with the
# current CLOSE_RE-based hook; the migration is what fixes them.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/enforce-issue-close.js"

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

if [ ! -f "$HOOK" ]; then
    echo "FAIL: precondition missing — hooks/enforce-issue-close.js"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

run_hook() {
    local json="$1"
    OUT=$(echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.fix334_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.fix334_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.fix334_hook_err.$$
}

run_hook_skilled() {
    local json="$1"
    OUT=$(echo "$json" | ISSUE_CLOSE_SKILL=1 run_with_timeout 15 node "$HOOK" 2>/tmp/.fix334_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.fix334_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.fix334_hook_err.$$
}

run_hook_no_env() {
    local json="$1"
    OUT=$(
        unset ISSUE_CLOSE_SKILL
        echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.fix334_hook_err.$$
    )
    RC=$?
    ERR=$(cat /tmp/.fix334_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.fix334_hook_err.$$
}

expect_block() {
    local desc="$1" json="$2"
    run_hook "$json"
    if [ "$RC" -eq 2 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 2 (rc=$RC stderr=$ERR)"
    fi
}

expect_approve() {
    local desc="$1" json="$2"
    run_hook "$json"
    if [ "$RC" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 0 (rc=$RC stderr=$ERR)"
    fi
}

# ============================================================================
# Block cases — bare close + segment-separator / launcher variants
# ============================================================================

expect_block "bare 'gh issue close 123'" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'

expect_block "'gh issue close 123 --reason completed'" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123 --reason completed"}}'

expect_block "segment separator: 'cd /tmp && gh issue close 123'" \
    '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && gh issue close 123"}}'

expect_block "launcher recursion: bash -c '\''gh issue close 123'\''" \
    '{"tool_name":"Bash","tool_input":{"command":"bash -c '\''gh issue close 123'\''"}}'

# ============================================================================
# Approve cases — false-positive prevention
# ============================================================================

expect_approve "gh issue comment with 'gh issue close 123' inside --body" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue comment 123 --body \"should we close this? gh issue close 123\""}}'

expect_approve "echo with 'gh issue close 123' in arg" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"gh issue close 123\""}}'

# ============================================================================
# Bypass regression
# ============================================================================

# Env bypass: ISSUE_CLOSE_SKILL=1 exported in environment
run_hook_skilled '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 0 ]; then
    pass "ISSUE_CLOSE_SKILL=1 env bypass preserved"
else
    fail "ISSUE_CLOSE_SKILL=1 env bypass — expected exit 0 (rc=$RC stderr=$ERR)"
fi

# Inline-shape bypass: ISSUE_CLOSE_SKILL=1 prefix inside the command string
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed"}}'
if [ "$RC" -eq 0 ]; then
    pass "inline ISSUE_CLOSE_SKILL=1 shape bypass preserved"
else
    fail "inline ISSUE_CLOSE_SKILL=1 shape — expected exit 0 (rc=$RC stderr=$ERR)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
