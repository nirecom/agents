#!/usr/bin/env bash
# Static tests for planner prompt files (issue #558).
# Checks that outline-planner.md and detail-planner.md adopt the 3-value triage enum.
# Will FAIL until planner prompt changes land (test-first).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

OUTLINE_PLANNER="$AGENTS_ROOT/agents/outline-planner.md"
DETAIL_PLANNER="$AGENTS_ROOT/agents/detail-planner.md"

assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"
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
    local file="$1"
    local pattern="$2"
    local desc="$3"
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

echo "=== feature-558 planner prompts tests ==="
echo ""

echo "--- outline-planner.md ---"

# P1: contains MUST
assert_contains "$OUTLINE_PLANNER" "MUST" \
    "P1: agents/outline-planner.md contains 'MUST'"

# P2: contains OPTIONAL
assert_contains "$OUTLINE_PLANNER" "OPTIONAL" \
    "P2: agents/outline-planner.md contains 'OPTIONAL'"

# P3: contains NA
assert_contains "$OUTLINE_PLANNER" '\bNA\b' \
    "P3: agents/outline-planner.md contains 'NA'"

# P4: contains pre-tiered
assert_contains "$OUTLINE_PLANNER" "pre-tiered" \
    "P4: agents/outline-planner.md contains 'pre-tiered'"

# P9: does NOT contain "disposition: fix in scope" as a parse directive
assert_absent "$OUTLINE_PLANNER" 'disposition:[[:space:]]*fix in scope' \
    "P9: agents/outline-planner.md does NOT contain 'disposition: fix in scope' as parse directive"

echo ""
echo "--- detail-planner.md ---"

# P5: contains MUST
assert_contains "$DETAIL_PLANNER" "MUST" \
    "P5: agents/detail-planner.md contains 'MUST'"

# P6: contains OPTIONAL
assert_contains "$DETAIL_PLANNER" "OPTIONAL" \
    "P6: agents/detail-planner.md contains 'OPTIONAL'"

# P7: contains NA
assert_contains "$DETAIL_PLANNER" '\bNA\b' \
    "P7: agents/detail-planner.md contains 'NA'"

# P8: contains pre-tiered
assert_contains "$DETAIL_PLANNER" "pre-tiered" \
    "P8: agents/detail-planner.md contains 'pre-tiered'"

# P10: does NOT contain "disposition: fix in scope" as a parse directive
assert_absent "$DETAIL_PLANNER" 'disposition:[[:space:]]*fix in scope' \
    "P10: agents/detail-planner.md does NOT contain 'disposition: fix in scope' as parse directive"

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
