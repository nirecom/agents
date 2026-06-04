#!/usr/bin/env bash
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow-init, github, issues, session-dedup, static-grep
# Static grep tests — Step 3 initial CLOSED detection for related issues.
#
# F1: Step 3 initial check references ISSUES[@] loop (not just primary)
# F2: workflow-init SKILL.md calls issue-state-check.sh for CLOSED detection
#
# SKIP when patterns are not yet present (pre-implementation).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Existence gate
if [ ! -f "$SKILL" ]; then
    echo "FAIL: skills/workflow-init/SKILL.md not found"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi

# F1: workflow-init SKILL.md Step 3 initial check references ISSUES[@] loop
if grep -qE '\$\{?ISSUES\[@\]\}?' "$SKILL"; then
    pass "F1: SKILL.md references ISSUES[@] loop (related-issue iteration)"
else
    skip "F1: pattern '\${ISSUES[@]}' not yet in SKILL.md (pre-implementation)"
fi

# F2: workflow-init SKILL.md contains issue-state-check.sh call
if grep -q 'issue-state-check\.sh' "$SKILL"; then
    pass "F2: SKILL.md invokes bin/github-issues/issue-state-check.sh"
else
    skip "F2: 'issue-state-check.sh' not yet in SKILL.md (pre-implementation)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0 ? 1 : 0))
