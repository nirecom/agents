#!/bin/bash
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow-init, wip-state, all-none, label-check, related-issues
# Tests for issue #589/#798 — workflow-init WI-5 ALL_NONE / WI-8 FORCE_PATH_B fallback.
#
# WI-5 ALL_NONE previously only checked whether the *primary* issue had the
# `intent:clarified` label; related issues without the label were silently
# routed to Path A (resume) instead of Path B (re-clarify), causing
# clarify-intent to be skipped for issues whose intent was never captured.
#
# The fix:
#   - WI-5 ALL_NONE evaluates all N's labels (not just primary).
#   - WI-8 introduces a FORCE_PATH_B fallback when any related N is unlabeled.
#   - WI-5 ERROR branch routes to AskUserQuestion (no silent warn-and-continue).
#
# RED before /write-code runs — these grep assertions match prose that
# /write-code will add to skills/workflow-init/SKILL.md.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$WORKFLOW_INIT_SKILL" ]; then
    echo "FAIL: precondition missing — skills/workflow-init/SKILL.md"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ============================================================================
# T1: WI-5 ALL_NONE condition covers all N (not just primary)
# ============================================================================
# The fixed SKILL.md must NOT contain prose limiting the ALL_NONE label check
# to the primary issue. Pre-fix text reads:
#   "ALL_NONE → if `intent:clarified` ∈ labels of primary: ..."
# Post-fix text must replace `primary` with all-N phrasing
# (e.g. "labels of all N", "every N", "each N in ISSUES").
ALL_NONE_LINE=$(grep -nE '^- `ALL_NONE`' "$WORKFLOW_INIT_SKILL" | head -1 || true)
if [ -z "$ALL_NONE_LINE" ]; then
    fail "T1: WI-5 ALL_NONE bullet not found in SKILL.md"
elif echo "$ALL_NONE_LINE" | grep -qiE "labels of primary[^a-zA-Z_]"; then
    fail "T1: WI-5 ALL_NONE still checks only 'labels of primary' — must cover all N"
elif echo "$ALL_NONE_LINE" | grep -qiE "(labels of all N|labels of every N|labels of each N|all N have|every N has|each N has|for all N|ALL_CLARIFIED)"; then
    pass "T1: WI-5 ALL_NONE condition covers all N (not just primary)"
else
    fail "T1: WI-5 ALL_NONE does not reference all N — may still check only primary; line: $ALL_NONE_LINE"
fi

# ============================================================================
# T2: WI-8 references FORCE_PATH_B fallback for related N without intent:clarified
# ============================================================================
if grep -qiE "(FORCE_PATH_B|force.path.b|force path B)" "$WORKFLOW_INIT_SKILL"; then
    pass "T2: WI-8 references FORCE_PATH_B fallback for related N without intent:clarified"
else
    fail "T2: WI-8 does not reference FORCE_PATH_B — related N without label may still route to Path A"
fi

# ============================================================================
# T3: WI-5 ERROR branch references AskUserQuestion (no silent warn-and-continue)
# ============================================================================
# The pre-fix behavior was to warn-and-continue when wip-state detection
# failed. The fix (rc=2 escalation, #589) routes to AskUserQuestion so the
# user is forced to resolve ambiguity before the workflow proceeds.
ERROR_LINE=$(grep -nE '^- `ERROR' "$WORKFLOW_INIT_SKILL" | head -1 || true)
if [ -z "$ERROR_LINE" ]; then
    fail "T3: WI-5 ERROR bullet not found in SKILL.md"
elif echo "$ERROR_LINE" | grep -qiE "(AskUserQuestion|ask.*user.*question)"; then
    pass "T3: WI-5 ERROR branch references AskUserQuestion"
else
    fail "T3: WI-5 ERROR branch does not reference AskUserQuestion — may still silently warn; line: $ERROR_LINE"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
