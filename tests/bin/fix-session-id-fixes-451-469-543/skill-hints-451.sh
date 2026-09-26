# skill-hints-451.sh — #451 SKILL.md session-id-failure hint grep tests (A1, A2).
# Sourced by fix-session-id-fixes-451-469-543.sh; inherits globals and helpers.

# === #451 grep tests ===

if [ -f "$CLARIFY_SKILL" ]; then
    if grep -nE 'rc=2' "$CLARIFY_SKILL" | grep -q 'CLAUDE_SESSION_ID'; then
        pass "A1: clarify-intent SKILL.md rc=2 hint mentions CLAUDE_SESSION_ID"
    else
        fail "A1: clarify-intent SKILL.md rc=2 hint does NOT mention CLAUDE_SESSION_ID"
    fi
else
    fail "A1: $CLARIFY_SKILL not found"
fi

if [ -f "$WI_SKILL" ]; then
    if grep -nE 'session-id resolution failure|WIP check failed' "$WI_SKILL" \
            | grep -q 'CLAUDE_SESSION_ID'; then
        pass "A2: workflow-init SKILL.md session-id error hint mentions CLAUDE_SESSION_ID"
    else
        fail "A2: workflow-init SKILL.md session-id error hint does NOT mention CLAUDE_SESSION_ID"
    fi
else
    fail "A2: $WI_SKILL not found"
fi
