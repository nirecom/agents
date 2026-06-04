#!/usr/bin/env bash
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow-init, github, issues, session-dedup, static-grep
# Static grep tests — Step 3(a) post-WIP CLOSED check and related guards.
#
# F3: Step 3(a) post-WIP CLOSED check present
# F4: AskUserQuestion has Remove option for related issue CLOSED
# F5: CLOSED check uses warn-continue for error
# F6: CLOSED check appears AFTER wip-state.sh call (insertion-point regression)
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

# F3: Step 3(a) post-WIP CLOSED check is present.
# Recognized by an issue-state-check.sh invocation AND a CLOSED literal nearby.
if grep -q 'issue-state-check\.sh' "$SKILL" && grep -qE '\bCLOSED\b' "$SKILL"; then
    pass "F3: Step 3(a) post-WIP CLOSED check present (issue-state-check.sh + CLOSED)"
else
    skip "F3: post-WIP CLOSED check not yet in SKILL.md (pre-implementation)"
fi

# F4: AskUserQuestion option for related issue CLOSED — Remove option.
# Recognized by 'Remove' appearing in an AskUserQuestion context.
if grep -qiE 'Remove.*(from|closes_issues|related)' "$SKILL" \
   || grep -qE '"label":\s*"Remove' "$SKILL"; then
    pass "F4: AskUserQuestion has 'Remove' option for related CLOSED issue"
else
    skip "F4: Remove option not yet in SKILL.md (pre-implementation)"
fi

# F5: CLOSED check uses warn-continue for error result.
# Recognized by 'warn-continue' or 'warn and continue' phrasing near 'error'.
if grep -qiE 'warn[- ]continue' "$SKILL" || grep -qE 'warn.*continue.*error|error.*warn.*continue' "$SKILL"; then
    pass "F5: CLOSED check uses warn-continue posture on error"
else
    skip "F5: 'warn-continue' phrasing not yet in SKILL.md (pre-implementation)"
fi

# F6: CLOSED check appears AFTER wip-state.sh call (insertion-point regression).
# Compare line numbers of first wip-state.sh and first issue-state-check.sh references.
WIP_LINE=$(grep -n 'wip-state\.sh' "$SKILL" 2>/dev/null | head -1 | cut -d: -f1)
ISC_LINE=$(grep -n 'issue-state-check\.sh' "$SKILL" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$WIP_LINE" ] && [ -n "$ISC_LINE" ]; then
    if [ "$ISC_LINE" -gt "$WIP_LINE" ]; then
        pass "F6: CLOSED check (line $ISC_LINE) appears AFTER wip-state.sh (line $WIP_LINE)"
    else
        fail "F6: insertion-point regression — issue-state-check (line $ISC_LINE) precedes wip-state (line $WIP_LINE)"
    fi
else
    skip "F6: ordering check skipped — wip-state=$WIP_LINE issue-state-check=$ISC_LINE (pre-implementation)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0 ? 1 : 0))
