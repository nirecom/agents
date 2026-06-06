#!/bin/bash
# Tests: CLAUDE.md, rules/docs/history.md, rules/docs/changelog.md, rules/github-issues.md
# Tags: step-6i, corrective-fix, we-20, issue-614
# Verifies "Step 6i" is removed from corrective targets and "WE-20" replaces it.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check_absent() {
    local label="$1"
    local literal="$2"
    local rel="$3"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: $rel missing"
        return
    fi
    if grep -qF "$literal" "$path"; then
        fail "$label: '$literal' still present in $rel"
    else
        pass "$label: '$literal' absent from $rel"
    fi
}

# C1: "Step 6i" absent from CLAUDE.md
check_absent "C1" "Step 6i" "CLAUDE.md"

# C2: "Step 6i" absent from rules/docs/history.md
check_absent "C2" "Step 6i" "rules/docs/history.md"

# C3: "Step 6i" absent from rules/docs/changelog.md
check_absent "C3" "Step 6i" "rules/docs/changelog.md"

# C4: "WE-20" appears >= 3 times total across the four files combined
total=0
for rel in "CLAUDE.md" "rules/docs/history.md" "rules/docs/changelog.md" "rules/github-issues.md"; do
    path="$AGENTS_DIR/$rel"
    if [ -f "$path" ]; then
        count=$(grep -cF "WE-20" "$path" 2>/dev/null)
        if [ -z "$count" ]; then count=0; fi
        total=$((total + count))
    fi
done
if [ "$total" -ge 3 ]; then
    pass "C4: 'WE-20' appears $total times (>= 3) across CLAUDE.md + rules/docs/history.md + rules/docs/changelog.md + rules/github-issues.md"
else
    fail "C4: 'WE-20' appears only $total times across the four files (need >= 3)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
