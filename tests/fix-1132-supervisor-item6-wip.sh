#!/usr/bin/env bash
# tests/fix-1132-supervisor-item6-wip.sh
# Tests: agents/supervisor.md, skills/_shared/off-legitimacy-rubric.md
# Tags: supervisor, off-legitimacy, rubric, wip-mode, content-assertion, scope:issue-specific, pwsh-not-required, TL1
#
# #1132: supervisor.md checklist item 6 must recognize `git -c workflow.wip=1 commit`
# (--wip mode) as a SANCTIONED mechanism, NOT a C3 improvised OFF-sentinel bypass.
# The OFF-legitimacy rubric SSOT (skills/_shared/off-legitimacy-rubric.md) is the
# single source for REJECT/ALLOW categories and the --wip sanctioned note; item 6
# references it and carries a minimal inline --wip pointer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"
RUBRIC="$AGENTS_DIR/skills/_shared/off-legitimacy-rubric.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

has() { grep -qiE "$2" "$1" 2>/dev/null; }

# --- rubric SSOT file exists ---
if [ -f "$RUBRIC" ]; then
    pass "rubric SSOT skills/_shared/off-legitimacy-rubric.md exists"

    # REJECT enum members
    for cat in cleanup instructions-unread convenience; do
        if has "$RUBRIC" "$cat"; then pass "rubric lists REJECT category: $cat"
        else fail "RED-EXPECTED: rubric missing REJECT category: $cat"; fi
    done
    # ALLOW enum members
    for cat in workflow-bug trivial-change urgent-external; do
        if has "$RUBRIC" "$cat"; then pass "rubric lists ALLOW category: $cat"
        else fail "RED-EXPECTED: rubric missing ALLOW category: $cat"; fi
    done
    # REJECT/ALLOW verdict tokens present
    if has "$RUBRIC" "REJECT" && has "$RUBRIC" "ALLOW"; then
        pass "rubric documents REJECT and ALLOW verdicts"
    else
        fail "RED-EXPECTED: rubric missing REJECT/ALLOW verdict tokens"
    fi
    # WIP sanctioned note lives in the rubric SSOT
    if has "$RUBRIC" "workflow\.wip" && has "$RUBRIC" "sanctioned"; then
        pass "rubric documents git -c workflow.wip=1 as a sanctioned (non-OFF) mechanism"
    else
        fail "RED-EXPECTED: rubric missing --wip / workflow.wip sanctioned note"
    fi
else
    fail "RED-EXPECTED (not yet created): skills/_shared/off-legitimacy-rubric.md missing"
fi

# --- supervisor.md item 6: --wip recognition + rubric reference ---
if [ -f "$SUPERVISOR_MD" ]; then
    pass "agents/supervisor.md present (harness sanity)"

    if has "$SUPERVISOR_MD" "workflow\.wip|--wip"; then
        pass "supervisor.md item 6 references --wip / workflow.wip sanctioned mode"
    else
        fail "RED-EXPECTED: supervisor.md does not mention --wip / workflow.wip (#1132 core)"
    fi

    if has "$SUPERVISOR_MD" "off-legitimacy-rubric\.md"; then
        pass "supervisor.md references the off-legitimacy-rubric.md SSOT"
    else
        fail "RED-EXPECTED: supervisor.md does not reference off-legitimacy-rubric.md"
    fi
else
    fail "agents/supervisor.md missing (harness error)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
