#!/bin/bash
# tests/feature-885-enforce-issue-close-ssot-import.sh
# Tests: hooks/enforce-issue-close.js
# Tags: enforce-issue-close, ssot, inline-skill-re, axis-a, feature-885
# Tests for issue #885 — INLINE_SKILL_RE moves to hooks/lib/block-predicates.js
# (SSOT). enforce-issue-close.js must require() it from there and must not
# redefine it inline. Also verifies behavioral compatibility unchanged.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/enforce-issue-close.js"
PREDICATES="$AGENTS_DIR/hooks/lib/block-predicates.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$HOOK" ]; then
    skip "enforce-issue-close.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- IC1: source no longer defines INLINE_SKILL_RE inline -------------------
# The inline form to detect: `const INLINE_SKILL_RE =` followed by a regex
# literal. After refactor, only `require(...)` or destructured import remains.
if grep -E '^[[:space:]]*const[[:space:]]+INLINE_SKILL_RE[[:space:]]*=[[:space:]]*/' "$HOOK" >/dev/null 2>&1; then
    fail "IC1: enforce-issue-close.js still defines INLINE_SKILL_RE inline (should import from block-predicates)"
else
    pass "IC1: enforce-issue-close.js no longer defines INLINE_SKILL_RE inline"
fi

# --- IC2: source DOES require block-predicates ------------------------------
if grep -E 'require\(.*block-predicates' "$HOOK" >/dev/null 2>&1; then
    pass "IC2: enforce-issue-close.js requires block-predicates"
else
    fail "IC2: enforce-issue-close.js does NOT require block-predicates"
fi

# --- IC3: hook does NOT pass co_blocked_by to reportBlock -------------------
# Sweep: grep for any reportBlock(...) call that includes co_blocked_by.
# The writer back-annotates this field; the hook must not.
if grep -E 'reportBlock\(.*co_blocked_by' "$HOOK" >/dev/null 2>&1; then
    fail "IC3: enforce-issue-close.js passes co_blocked_by to reportBlock (writer should back-annotate)"
else
    pass "IC3: enforce-issue-close.js does not pass co_blocked_by to reportBlock"
fi

# --- IC4: behavioral regression — bare `gh issue close` still blocked ------
expect_block() {
    local desc="$1" json="$2"
    OUT=$(echo "$json" | run_with_timeout 15 node "$HOOK" 2>/tmp/.ic_err.$$)
    RC=$?
    ERR=$(cat /tmp/.ic_err.$$ 2>/dev/null)
    rm -f /tmp/.ic_err.$$
    if [ "$RC" -eq 2 ]; then
        pass "$desc"
    else
        fail "$desc (rc=$RC, err=$ERR)"
    fi
}

expect_block "IC4: bare 'gh issue close 123' still blocked (rc=2)" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue close 123"}}'

# --- IC5: behavioral regression — inline form still passes ------------------
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed"}}' | \
    run_with_timeout 15 node "$HOOK" 2>/tmp/.ic_err.$$)
RC=$?
rm -f /tmp/.ic_err.$$
if [ "$RC" -eq 0 ]; then
    pass "IC5: inline 'ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed' still passes"
else
    fail "IC5: inline shape blocked (rc=$RC)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
