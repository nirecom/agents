#!/bin/bash
# Tests: agents/outline-planner.md
# Tags: outline, planning, agent, cross-component, architect
# Static grep-based checks for outline-planner cross-component integrity rule (#674).
#
# Verifies that agents/outline-planner.md contains the mandatory
# Cross-component risks field and the associated checking instructions.
#
# All checks must PASS when outline-planner.md contains the cross-component risk instructions.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
has_fixed() { grep -F -- "$1" "$2" >/dev/null 2>&1; }
require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

PLANNER="$REPO_ROOT/agents/outline-planner.md"

# ---------------------------------------------------------------------------
echo "=== outline-planner.md: cross-component structural integrity rule (#674) ==="
if require_file "$PLANNER"; then
    for needle in "Cross-component risks:" "component contract" "dependency" "responsibility"; do
        if has_fixed "$needle" "$PLANNER"; then
            pass "outline-planner.md contains '$needle'"
        else
            fail "outline-planner.md missing '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed."
    exit 0
else
    echo "$ERRORS check(s) failed."
    exit 1
fi
