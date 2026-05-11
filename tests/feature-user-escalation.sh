#!/usr/bin/env bash
# Structural tests for rules/user-escalation.md
# Validates: existence, required headings, Decision Flow ordering, regression guards

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULE_FILE="$REPO_ROOT/rules/user-escalation.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi
    if grep -qE "$pattern" "$file"; then
        pass "$desc"
    else
        fail "$desc (pattern not found: $pattern)"
    fi
}

assert_absent() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi
    if grep -qE "$pattern" "$file"; then
        fail "$desc (pattern unexpectedly found: $pattern)"
    else
        pass "$desc"
    fi
}

echo "=== feature-user-escalation structural tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases — file existence and non-emptiness
# ---------------------------------------------------------------------------
echo "--- Normal ---"

# N1: file exists
if [ -f "$RULE_FILE" ]; then
    pass "N1: rules/user-escalation.md exists"
else
    fail "N1: rules/user-escalation.md exists"
fi

# N2: file is non-empty
if [ -s "$RULE_FILE" ]; then
    pass "N2: rules/user-escalation.md is non-empty"
else
    fail "N2: rules/user-escalation.md is non-empty"
fi

# N3: required heading — Decision Flow
assert_contains "$RULE_FILE" "^## Decision Flow" \
    "N3: '## Decision Flow' heading present"

# N4: required heading — Rule 1
assert_contains "$RULE_FILE" "^## Rule 1" \
    "N4: '## Rule 1' heading present"

# N5: required heading — Rule 2
assert_contains "$RULE_FILE" "^## Rule 2" \
    "N5: '## Rule 2' heading present"

# N6: required heading — Rule 3
assert_contains "$RULE_FILE" "^## Rule 3" \
    "N6: '## Rule 3' heading present"

# N7: required heading — Precedence
assert_contains "$RULE_FILE" "^## Precedence" \
    "N7: '## Precedence' heading present"

echo ""
# ---------------------------------------------------------------------------
# Ordering safety — destructive check must precede "Can CC execute" check
# ---------------------------------------------------------------------------
echo "--- Ordering (Decision Flow) ---"

# N8: destructive row appears before the "Can Claude Code execute" row
# Strategy: find the line numbers of each and compare
if [ -f "$RULE_FILE" ]; then
    line_destructive=$(grep -nE "destructive" "$RULE_FILE" | grep -v "^#" | head -1 | cut -d: -f1)
    line_execute=$(grep -nE "Can Claude Code execute" "$RULE_FILE" | head -1 | cut -d: -f1)
    if [ -n "$line_destructive" ] && [ -n "$line_execute" ]; then
        if [ "$line_destructive" -lt "$line_execute" ]; then
            pass "N8: destructive check row ($line_destructive) appears before 'Can CC execute' row ($line_execute)"
        else
            fail "N8: destructive check row ($line_destructive) must appear before 'Can CC execute' row ($line_execute)"
        fi
    else
        fail "N8: could not locate destructive ($line_destructive) or 'Can CC execute' ($line_execute) rows"
    fi
fi

echo ""
# ---------------------------------------------------------------------------
# Regression guards
# ---------------------------------------------------------------------------
echo "--- Regression guards ---"

# R1: must not contain 'npm run migrate' (destructive example regression guard)
assert_absent "$RULE_FILE" "npm run migrate" \
    "R1: does not contain 'npm run migrate'"

echo ""
# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
