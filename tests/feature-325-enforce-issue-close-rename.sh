#!/bin/bash
# Tests for issue #325 — hooks/enforce-issue-close.js error message update.
#
# After the /issue-close split, the hook's error message must mention BOTH
# new skill names (/issue-close-stage and /issue-close-finalize), so the
# user can route to the correct phase.
#
# Regression: bare `gh issue close` is still blocked, and the
# ISSUE_CLOSE_SKILL=1 env-bypass / inline-shape still pass.
#
# RED: this suite fails clean while hooks/enforce-issue-close.js lacks
# updated error text (also fails clean if file missing entirely).

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

# Pre-check that the hook has been updated for the rename. If the body
# does not yet reference /issue-close-finalize, we're still in RED: the
# behavior tests below need the new error wording to pass.
if ! grep -q "issue-close-finalize" "$HOOK"; then
    echo "FAIL: precondition missing — hooks/enforce-issue-close.js does not mention /issue-close-finalize (rename pending)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

run_hook() {
    local json="$1"
    OUT=$(echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.enforce_hook_err.$$
    return $RC
}

run_hook_skilled() {
    local json="$1"
    OUT=$(echo "$json" | ISSUE_CLOSE_SKILL=1 run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$)
    RC=$?
    ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.enforce_hook_err.$$
    return $RC
}

run_hook_no_env() {
    local json="$1"
    OUT=$(
        unset ISSUE_CLOSE_SKILL
        echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.enforce_hook_err.$$
    )
    RC=$?
    ERR=$(cat /tmp/.enforce_hook_err.$$ 2>/dev/null)
    rm -f /tmp/.enforce_hook_err.$$
    return $RC
}

expect_block() {
    local desc="$1" json="$2"
    run_hook "$json"
    if [ "$RC" -eq 2 ] && (echo "$ERR" | grep -q "issue-close-finalize" || echo "$ERR" | grep -q "issue-close-stage"); then
        pass "$desc"
    else
        fail "$desc — expected exit 2 + new skill name in stderr (rc=$RC stderr=$ERR)"
    fi
}

# ============================================================================
# H-series — error message update + bypass regression
# ============================================================================

# --- H1: bare gh issue close still blocked
expect_block "H1: bare 'gh issue close 123' still blocked" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'

# --- H2: ISSUE_CLOSE_SKILL=1 env bypass still works
run_hook_skilled '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 0 ]; then
    pass "H2: ISSUE_CLOSE_SKILL=1 bypass preserved"
else
    fail "H2: rc=$RC"
fi

# --- H3: error message mentions /issue-close-finalize
run_hook '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q "issue-close-finalize"; then
    pass "H3: error message mentions /issue-close-finalize"
else
    fail "H3: rc=$RC stderr=$ERR"
fi

# --- H4: error message mentions /issue-close-stage (Phase 1 context)
run_hook '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'
if [ "$RC" -eq 2 ] && echo "$ERR" | grep -q "issue-close-stage"; then
    pass "H4: error message mentions /issue-close-stage"
else
    fail "H4: rc=$RC stderr=$ERR"
fi

# --- H5: ISSUE_CLOSE_SKILL=1 ... --reason completed inline shape still passes
run_hook_no_env '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed"}}'
if [ "$RC" -eq 0 ]; then
    pass "H5: inline skill shape still passes (INLINE_SKILL_RE unchanged)"
else
    fail "H5: rc=$RC stderr=$ERR"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
