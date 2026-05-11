#!/bin/bash
# Tests for hooks/enforce-issue-close.js — PreToolUse hook that blocks bare
# `gh issue close` invocations unless the /issue-close skill set
# ISSUE_CLOSE_SKILL=1 in the environment.
#
# RED: this suite fails clean while hooks/enforce-issue-close.js is missing.

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
    echo "FAIL: hooks/enforce-issue-close.js not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Run hook with given JSON, return exit code; stdout in $OUT, stderr in $ERR.
run_hook() {
    local json="$1"
    OUT=$(echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.enforce_hook_err.$$
    return $RC
}

# Same, but with ISSUE_CLOSE_SKILL=1 in env
run_hook_skilled() {
    local json="$1"
    OUT=$(echo "$json" | ISSUE_CLOSE_SKILL=1 run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.enforce_hook_err.$$
    return $RC
}

expect_block() {
    local desc="$1" json="$2"
    run_hook "$json"
    if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q "/issue-close"; then
        pass "$desc"
    else
        fail "$desc — expected exit 2 + /issue-close stderr (rc=$RC stderr=$ERR)"
    fi
}

expect_pass() {
    local desc="$1" json="$2"
    run_hook "$json"
    if [ "$RC" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 0 (rc=$RC stderr=$ERR)"
    fi
}

# --- N1: bare gh issue close ---
expect_block "N1: bare 'gh issue close 123' is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'

# --- N2: with --reason completed ---
expect_block "N2: 'gh issue close 123 --reason completed' is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123 --reason completed"}}'

# --- N3: chained with && ---
expect_block "N3: 'echo done && gh issue close 123' is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"echo done && gh issue close 123"}}'

# --- N4: chained with ; ---
expect_block "N4: 'gh issue close 123; echo done' is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123; echo done"}}'

# --- N5: piped ---
expect_block "N5: 'gh issue close 123 | cat' is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123 | cat"}}'

# --- N6: ISSUE_CLOSE_SKILL=1 → pass ---
run_hook_skilled '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 0 ]; then
    pass "N6: ISSUE_CLOSE_SKILL=1 allows close"
else
    fail "N6: ISSUE_CLOSE_SKILL=1 allows close (rc=$RC)"
fi

# --- N7: tool_name=Write → passthrough ---
expect_pass "N7: Write tool_name passes through" \
    '{"tool_name":"Write","tool_input":{"file_path":"/x","content":"y"}}'

# --- N8: gh issue list → pass ---
expect_pass "N8: 'gh issue list' passes" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}'

# --- N9: gh issue create → pass ---
expect_pass "N9: 'gh issue create --title foo' passes" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue create --title foo"}}'

# --- N10: gh api PATCH on comments → pass ---
expect_pass "N10: 'gh api repos/.../issues/comments/123 -X PATCH' passes" \
    '{"tool_name":"Bash","tool_input":{"command":"gh api repos/owner/repo/issues/comments/123 -X PATCH"}}'

# --- E1: multiple spaces ---
expect_block "E1: 'gh  issue  close 123' (multiple spaces) is blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh  issue  close 123"}}'

# --- R1: invalid JSON → graceful ---
OUT=$(echo "NOT JSON" | run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$)
RC=$?
ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
rm -f /tmp/.enforce_hook_err.$$
# Acceptable: any non-crashing exit. Crashes typically yield rc>=1 with a node
# stack trace. We allow exit 0 (graceful pass) or exit 1 (graceful error), but
# not a stack trace.
if [ "$RC" -ne 2 ] && ! echo "$ERR" | grep -q "at Object\."; then
    pass "R1: invalid JSON handled gracefully (no node stack trace)"
else
    fail "R1: invalid JSON handled gracefully (rc=$RC stderr=$ERR)"
fi

# --- R2: empty input → exit 0 ---
OUT=$(printf "" | run_with_timeout 15 node "$HOOK" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "R2: empty input → exit 0"
else
    fail "R2: empty input → exit 0 (rc=$RC)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
