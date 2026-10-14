#!/bin/bash
# Tests: skills/write-code/SKILL.md
# Tags: skill, static, scope:common
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): what skills/write-code/SKILL.md must and must not contain.

# ---------------------------------------------------------------------------
# a. skills/write-code/SKILL.md exists
# ---------------------------------------------------------------------------
echo "=== a. SKILL.md exists ==="
if require_file "$WRITE_CODE_SKILL"; then
    pass "skills/write-code/SKILL.md exists"
fi

# ---------------------------------------------------------------------------
# b. SKILL.md contains the literal CONFIRM_CODE
# ---------------------------------------------------------------------------
echo "=== b. SKILL.md contains CONFIRM_CODE ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "CONFIRM_CODE" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'CONFIRM_CODE'"
    else
        fail "SKILL.md missing 'CONFIRM_CODE'"
    fi
fi

# ---------------------------------------------------------------------------
# c. SKILL.md gates WCD-6 via the shared next-step --gate trigger line
#    (bin/confirm-off retired from the gate sections by #2490)
# ---------------------------------------------------------------------------
echo "=== c. SKILL.md contains the next-step --gate trigger line ==="
GATE_TRIGGER='Gate check: apply skills/_shared/confirm-plan.md CPA-3 — run next-step --gate and follow GATE_ACTION.'
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "$GATE_TRIGGER" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains the next-step --gate trigger line"
    else
        fail "SKILL.md missing the next-step --gate trigger line"
    fi
fi

# ---------------------------------------------------------------------------
# d. SKILL.md dispatches complexity-judge subagent
# ---------------------------------------------------------------------------
echo "=== d. SKILL.md dispatches complexity-judge subagent ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "complexity-judge" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'complexity-judge'"
    else
        fail "SKILL.md missing 'complexity-judge'"
    fi
fi

# ---------------------------------------------------------------------------
# e. SKILL.md does NOT contain ENFORCE_WORKTREE
# ---------------------------------------------------------------------------
echo "=== e. SKILL.md does NOT contain ENFORCE_WORKTREE ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "ENFORCE_WORKTREE" "$WRITE_CODE_SKILL"; then
        fail "SKILL.md must NOT contain 'ENFORCE_WORKTREE'"
    else
        pass "SKILL.md correctly omits 'ENFORCE_WORKTREE'"
    fi
fi

# ---------------------------------------------------------------------------
# f. SKILL.md does NOT contain diff-presentation phrases
# ---------------------------------------------------------------------------
echo "=== f. SKILL.md does NOT contain diff-presentation phrases ==="
if require_file "$WRITE_CODE_SKILL"; then
    for phrase in "Present a diff" "chat-level diff" "diff in chat"; do
        if has_fixed "$phrase" "$WRITE_CODE_SKILL"; then
            fail "SKILL.md must NOT contain '$phrase'"
        else
            pass "SKILL.md correctly omits '$phrase'"
        fi
    done
fi
