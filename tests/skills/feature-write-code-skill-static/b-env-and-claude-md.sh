#!/bin/bash
# Tests: CLAUDE.md
# Tags: skill, env, config, static, scope:common
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): .env.example's CONFIRM_CODE and CLAUDE.md's write-code step docs.

# ---------------------------------------------------------------------------
# g. .env.example contains CONFIRM_CODE=
# ---------------------------------------------------------------------------
echo "=== g. .env.example contains CONFIRM_CODE= ==="
if require_file "$ENV_EXAMPLE"; then
    if grep -E "^CONFIRM_CODE=" "$ENV_EXAMPLE" >/dev/null 2>&1; then
        pass ".env.example defines CONFIRM_CODE="
    else
        fail ".env.example missing CONFIRM_CODE= line"
    fi
fi

# ---------------------------------------------------------------------------
# h. CLAUDE.md does NOT contain "Present a diff in chat"
#    (per-step WF-CODE-N headers were removed from CLAUDE.md; the whole file
#     is the scope now — the step list lives in bin/workflow/next-step --list)
# ---------------------------------------------------------------------------
echo "=== h. CLAUDE.md does NOT contain 'Present a diff in chat' ==="
if require_file "$CLAUDE_MD"; then
    if has_fixed "Present a diff in chat" "$CLAUDE_MD"; then
        fail "CLAUDE.md must NOT contain 'Present a diff in chat'"
    else
        pass "CLAUDE.md does not contain 'Present a diff in chat'"
    fi
fi

# ---------------------------------------------------------------------------
# i. CLAUDE.md does NOT contain old ENFORCE_WORKTREE=off diff branching pattern
# ---------------------------------------------------------------------------
echo "=== i. CLAUDE.md does NOT contain old diff branching pattern ==="
if require_file "$CLAUDE_MD"; then
    # Old pattern was two lines both present: ENFORCE_WORKTREE=off AND Present a diff
    if has_fixed "ENFORCE_WORKTREE=off" "$CLAUDE_MD" && \
       has_fixed "Present a diff" "$CLAUDE_MD"; then
        fail "CLAUDE.md still has old ENFORCE_WORKTREE=off + Present a diff branching pattern"
    else
        pass "CLAUDE.md does not have old diff branching pattern"
    fi
fi

# ---------------------------------------------------------------------------
# j. CLAUDE.md documents write-code as a manually-invoked, untracked step
# ---------------------------------------------------------------------------
echo "=== j. CLAUDE.md documents write-code as an untracked manual step ==="
if require_file "$CLAUDE_MD"; then
    if has_fixed "write-code" "$CLAUDE_MD"; then
        pass "CLAUDE.md references 'write-code'"
    else
        fail "CLAUDE.md missing reference to 'write-code'"
    fi
    if has_fixed 'is not a tracked `next-step` step' "$CLAUDE_MD"; then
        pass "CLAUDE.md states write-code 'is not a tracked \`next-step\` step'"
    else
        fail "CLAUDE.md missing 'is not a tracked \`next-step\` step' note for write-code"
    fi
fi
