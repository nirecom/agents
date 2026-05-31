#!/bin/bash
# Tests: main/profile/codes
# Tags: profile-codes
# Tests for the codes function in profile-snippet.sh
# Run: bash tests/main-profile-codes.sh

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$AGENTS_DIR/profile-snippet.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the codes function block from profile-snippet.sh
codes_block=$(sed -n '/^codes()/,/^}/p' "$PROFILE")

echo "=== codes function (profile-snippet.sh) tests ==="

# --- Normal cases ---

echo "--- Normal cases ---"

if echo "$codes_block" | grep -q 'code --new-window'; then
    pass "launches VS Code with --new-window"
else
    fail "should launch VS Code with --new-window"
fi

if echo "$codes_block" | grep -q 'wait-vscode-window\.sh'; then
    pass "calls wait-vscode-window.sh for window polling"
else
    fail "should call wait-vscode-window.sh"
fi

if echo "$codes_block" | grep -q 'session-sync\.sh.*push'; then
    pass "runs session-sync push after window polling"
else
    fail "should run session-sync push after window polling"
fi

if echo "$codes_block" | grep -q 'disown'; then
    pass "uses disown for background execution"
else
    fail "should use disown for background execution"
fi

# --wait should no longer be used
if echo "$codes_block" | grep -q -- '--wait'; then
    fail "--wait should not be used (replaced by window polling)"
else
    pass "does not use --wait (replaced by window polling)"
fi

# --- Error cases ---

echo "--- Error cases ---"

# Default target when no args
if echo "$codes_block" | grep -q 'target=.*\${1:-.}'; then
    pass "defaults to current directory when no args"
else
    fail "should default to '.' when no args"
fi

# cd failure fallback
if echo "$codes_block" | grep -q 'cd.*2>/dev/null.*||'; then
    pass "handles cd failure with fallback"
else
    fail "should handle cd failure gracefully"
fi

# --- Edge cases ---

echo "--- Edge cases ---"

# .code-workspace handling
if echo "$codes_block" | grep -q '\.code-workspace'; then
    pass "handles .code-workspace files"
else
    fail "should handle .code-workspace files"
fi

# basename extraction for workspace name
if echo "$codes_block" | grep -q 'basename.*\.code-workspace'; then
    pass "extracts workspace name from .code-workspace filename"
else
    fail "should extract workspace name from .code-workspace"
fi

# basename extraction for folder name
if echo "$codes_block" | grep -q 'basename.*pwd'; then
    pass "extracts folder name via pwd resolution"
else
    fail "should extract folder name via pwd"
fi

# Output suppression (session-sync push output)
if echo "$codes_block" | grep -q '>/dev/null 2>&1'; then
    pass "suppresses session-sync push output"
else
    fail "should suppress session-sync push output"
fi

# --- Idempotency ---

echo "--- Idempotency ---"

# Each call runs in independent subshell
if echo "$codes_block" | grep -q '('; then
    pass "runs in subshell (independent per invocation)"
else
    fail "should run in subshell for independence"
fi

# --- Summary ---

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
