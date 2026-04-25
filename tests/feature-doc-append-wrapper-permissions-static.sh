#!/bin/bash
# Static validation: settings.json permission rules for doc-append wrapper
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$DOTFILES/claude-global/settings.json"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# --- Check old rule is removed ---
if grep -q '"Bash(uv run bin/doc-append.py *)"' "$SETTINGS"; then
    fail "Old allow rule 'Bash(uv run bin/doc-append.py *)' still present"
else
    pass "Old allow rule removed"
fi

# --- Check new rules exist ---
if grep -q '"Bash(doc-append *)"' "$SETTINGS"; then
    pass "New allow rule 'Bash(doc-append *)' present"
else
    fail "Missing allow rule: 'Bash(doc-append *)'"
fi


echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed!"
else
    echo "$ERRORS check(s) failed"
    exit 1
fi
