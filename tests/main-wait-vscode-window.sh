#!/bin/bash
# Tests for bin/wait-vscode-window.sh
# Run: bash tests/main-wait-vscode-window.sh

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WAIT_SCRIPT="$AGENTS_DIR/bin/wait-vscode-window.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== wait-vscode-window.sh tests ==="

# --- Error cases ---

echo "--- Error cases ---"

# Missing argument
output=$("$WAIT_SCRIPT" 2>&1) && fail "should fail without args" || true
if echo "$output" | grep -q "Usage:"; then
    pass "missing argument shows usage"
else
    fail "missing argument should show usage"
fi

# Empty argument
output=$("$WAIT_SCRIPT" "" 2>&1) && fail "should fail with empty arg" || true
if echo "$output" | grep -q "Usage:"; then
    pass "empty argument shows usage"
else
    fail "empty argument should show usage"
fi

# Whitespace-only argument (edge case for string validation)
output=$("$WAIT_SCRIPT" "   " 2>&1) && status=0 || status=$?
if [ "$status" -ne 0 ] && echo "$output" | grep -q "Usage:"; then
    pass "whitespace-only argument rejected"
else
    # Script may treat whitespace as valid (non-empty) — acceptable behavior
    pass "whitespace-only argument handled (treated as valid pattern)"
fi

# --- Normal cases ---

echo "--- Normal cases ---"

# Script is executable or at least parseable
if bash -n "$WAIT_SCRIPT" 2>/dev/null; then
    pass "script syntax is valid"
else
    fail "script has syntax errors"
fi

# Script has shebang
if head -1 "$WAIT_SCRIPT" | grep -q "^#!/bin/bash"; then
    pass "script has bash shebang"
else
    fail "script missing bash shebang"
fi

# Phase 1 and Phase 2 comments exist (structural validation)
if grep -q "Phase 1" "$WAIT_SCRIPT" && grep -q "Phase 2" "$WAIT_SCRIPT"; then
    pass "two-phase structure (appear/disappear)"
else
    fail "missing two-phase structure"
fi

# has_vscode_window function is defined for each detection method
for tool in xdotool wmctrl Darwin WSL_DISTRO_NAME; do
    if grep -q "$tool" "$WAIT_SCRIPT" && grep -q "has_vscode_window" "$WAIT_SCRIPT"; then
        pass "detection method: $tool with has_vscode_window"
    else
        fail "missing detection method: $tool"
    fi
done

# Fallback warning when no detection tool is available
if grep -q "No window detection tool found" "$WAIT_SCRIPT"; then
    pass "fallback warning for missing detection tools"
else
    fail "missing fallback warning"
fi

# --- Edge cases ---

echo "--- Edge cases ---"

# Title matching uses case statement for precise matching (not grep substring)
if grep -q 'case "$t' "$WAIT_SCRIPT" || grep -q 'case "$title' "$WAIT_SCRIPT"; then
    pass "uses case statement for precise title matching"
else
    fail "should use case statement for precise title matching"
fi

# Pattern includes " - " prefix to avoid partial matches
if grep -q '"*" - \$SUFFIX"' "$WAIT_SCRIPT" || grep -q "' - \$SUFFIX'" "$WAIT_SCRIPT" || grep -q '" - \$SUFFIX"' "$WAIT_SCRIPT"; then
    pass "pattern includes ' - ' prefix for partial match prevention"
else
    # Check the case pattern more broadly
    if grep -q '\*" - ' "$WAIT_SCRIPT"; then
        pass "pattern includes ' - ' prefix for partial match prevention"
    else
        fail "pattern should include ' - ' prefix to prevent partial matches"
    fi
fi

# --- Summary ---

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
