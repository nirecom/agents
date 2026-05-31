#!/bin/bash
# Tests: skills/_shared/judge-task-complexity.md, skills/write-code/SKILL.md
# Tags: write-code-skill-static
# Static grep-based checks for the /write-code skill implementation.
#
# Verifies that skills/write-code/SKILL.md exists with correct content,
# that CLAUDE.md Step 5 routes through /write-code, that .env.example
# defines CONFIRM_CODE, and that module-system guidance respects SSOT
# (nodejs.md is the canonical source; SKILL.md must not duplicate it).
#
# Pre-implementation: assertions are expected to FAIL until the skill is
# implemented. The script does not abort on individual assertion failures.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

has() {
    grep -E -- "$1" "$2" >/dev/null 2>&1
}
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

WRITE_CODE_SKILL="$REPO_ROOT/skills/write-code/SKILL.md"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
NODEJS_RULES="$REPO_ROOT/rules/coding/nodejs.md"
PYTHON_RULES="$REPO_ROOT/rules/coding/python.md"

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
# c. SKILL.md contains `get-config-var --is-off CONFIRM_CODE`
# ---------------------------------------------------------------------------
echo "=== c. SKILL.md contains get-config-var --is-off CONFIRM_CODE ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "get-config-var --is-off CONFIRM_CODE" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'get-config-var --is-off CONFIRM_CODE'"
    else
        fail "SKILL.md missing 'get-config-var --is-off CONFIRM_CODE'"
    fi
fi

# ---------------------------------------------------------------------------
# d. SKILL.md contains judge-task-complexity
# ---------------------------------------------------------------------------
echo "=== d. SKILL.md contains judge-task-complexity ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "judge-task-complexity" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'judge-task-complexity'"
    else
        fail "SKILL.md missing 'judge-task-complexity'"
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
# h. CLAUDE.md Step 5 does NOT contain "Present a diff in chat"
# ---------------------------------------------------------------------------
echo "=== h. CLAUDE.md Step 5 does NOT contain 'Present a diff in chat' ==="
if require_file "$CLAUDE_MD"; then
    # Extract lines in the Step 5 block (between "5. **Code**" and next top-level step)
    step5_block=$(awk '/^5\. \*\*Code\*\*/{found=1} found && /^[0-9]+\. \*\*/ && !/^5\./{found=0} found{print}' "$CLAUDE_MD")
    if echo "$step5_block" | grep -F "Present a diff in chat" >/dev/null 2>&1; then
        fail "CLAUDE.md Step 5 must NOT contain 'Present a diff in chat'"
    else
        pass "CLAUDE.md Step 5 does not contain 'Present a diff in chat'"
    fi
fi

# ---------------------------------------------------------------------------
# i. CLAUDE.md Step 5 does NOT contain old ENFORCE_WORKTREE=off diff branching pattern
# ---------------------------------------------------------------------------
echo "=== i. CLAUDE.md Step 5 does NOT contain old diff branching pattern ==="
if require_file "$CLAUDE_MD"; then
    step5_block=$(awk '/^5\. \*\*Code\*\*/{found=1} found && /^[0-9]+\. \*\*/ && !/^5\./{found=0} found{print}' "$CLAUDE_MD")
    # Old pattern was two lines both present: ENFORCE_WORKTREE=off AND Present a diff
    if echo "$step5_block" | grep -F "ENFORCE_WORKTREE=off" >/dev/null 2>&1 && \
       echo "$step5_block" | grep -F "Present a diff" >/dev/null 2>&1; then
        fail "CLAUDE.md Step 5 still has old ENFORCE_WORKTREE=off + Present a diff branching pattern"
    else
        pass "CLAUDE.md Step 5 does not have old diff branching pattern"
    fi
fi

# ---------------------------------------------------------------------------
# j. CLAUDE.md Step 5 contains /write-code
# ---------------------------------------------------------------------------
echo "=== j. CLAUDE.md Step 5 contains /write-code ==="
if require_file "$CLAUDE_MD"; then
    step5_block=$(awk '/^5\. \*\*Code\*\*/{found=1} found && /^[0-9]+\. \*\*/ && !/^5\./{found=0} found{print}' "$CLAUDE_MD")
    if echo "$step5_block" | grep -F "/write-code" >/dev/null 2>&1; then
        pass "CLAUDE.md Step 5 contains '/write-code'"
    else
        fail "CLAUDE.md Step 5 missing '/write-code'"
    fi
fi

# ---------------------------------------------------------------------------
# k. rules/coding/python.md retains globs: frontmatter
# ---------------------------------------------------------------------------
echo "=== k. rules/coding/python.md has globs: frontmatter ==="
if require_file "$PYTHON_RULES"; then
    if head -10 "$PYTHON_RULES" | grep -F "globs:" >/dev/null 2>&1; then
        pass "rules/coding/python.md retains 'globs:' frontmatter"
    else
        fail "rules/coding/python.md missing 'globs:' in first 10 lines"
    fi
fi

# ---------------------------------------------------------------------------
# l. rules/coding/nodejs.md retains globs: frontmatter
# ---------------------------------------------------------------------------
echo "=== l. rules/coding/nodejs.md has globs: frontmatter ==="
if require_file "$NODEJS_RULES"; then
    if head -10 "$NODEJS_RULES" | grep -F "globs:" >/dev/null 2>&1; then
        pass "rules/coding/nodejs.md retains 'globs:' frontmatter"
    else
        fail "rules/coding/nodejs.md missing 'globs:' in first 10 lines"
    fi
fi

# ---------------------------------------------------------------------------
# m. Control-flow ordering: CONFIRM_CODE < judge-task-complexity < Agent tool
# ---------------------------------------------------------------------------
echo "=== m. Control-flow ordering in SKILL.md ==="
if require_file "$WRITE_CODE_SKILL"; then
    line_confirm=$(grep -n "CONFIRM_CODE" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_judge=$(grep -n "judge-task-complexity" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_agent=$(grep -n "Agent" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)

    if [ -z "$line_confirm" ] || [ -z "$line_judge" ] || [ -z "$line_agent" ]; then
        fail "control-flow ordering: could not find all three anchors (CONFIRM_CODE=$line_confirm, judge-task-complexity=$line_judge, Agent=$line_agent)"
    else
        if [ "$line_confirm" -lt "$line_judge" ] && [ "$line_judge" -lt "$line_agent" ]; then
            pass "control-flow ordering: CONFIRM_CODE (L$line_confirm) < judge-task-complexity (L$line_judge) < Agent (L$line_agent)"
        else
            fail "control-flow ordering wrong: CONFIRM_CODE=L$line_confirm, judge-task-complexity=L$line_judge, Agent=L$line_agent (expected ascending)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# n. SKILL.md contains "Model selected:" AND path to judge-task-complexity SKILL.md
# ---------------------------------------------------------------------------
echo "=== n. SKILL.md contains 'Model selected:' and judge-task-complexity/SKILL.md path ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "Model selected:" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'Model selected:'"
    else
        fail "SKILL.md missing 'Model selected:'"
    fi
    if has_fixed "skills/_shared/judge-task-complexity.md" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains path 'skills/_shared/judge-task-complexity.md'"
    else
        fail "SKILL.md missing path 'skills/_shared/judge-task-complexity.md'"
    fi
fi

# ---------------------------------------------------------------------------
# o. SKILL.md does NOT contain "skip silently"; DOES contain "check skipped"
# ---------------------------------------------------------------------------
echo "=== o. SKILL.md: no 'skip silently', has 'check skipped' ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "skip silently" "$WRITE_CODE_SKILL"; then
        fail "SKILL.md must NOT contain 'skip silently'"
    else
        pass "SKILL.md correctly omits 'skip silently'"
    fi
    if has_fixed "check skipped" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'check skipped'"
    else
        fail "SKILL.md missing 'check skipped'"
    fi
fi

# ---------------------------------------------------------------------------
# p. SSOT XOR: module-system guidance tokens must not appear in both nodejs.md and SKILL.md
# ---------------------------------------------------------------------------
echo "=== p. SSOT XOR: module-system guidance tokens ==="
if require_file "$NODEJS_RULES" && require_file "$WRITE_CODE_SKILL"; then
    for token in "module system" "CommonJS"; do
        if grep -F -- "$token" "$NODEJS_RULES" >/dev/null 2>&1; then
            # Token is canonical in nodejs.md — must NOT appear in SKILL.md
            if grep -F -- "$token" "$WRITE_CODE_SKILL" >/dev/null 2>&1; then
                fail "SSOT violation: '$token' is in nodejs.md (canonical) but also in SKILL.md (must not duplicate)"
            else
                pass "SSOT XOR ok: '$token' in nodejs.md, absent from SKILL.md"
            fi
        else
            pass "SSOT XOR skip: '$token' not in nodejs.md — no constraint on SKILL.md"
        fi
    done
fi

# ---------------------------------------------------------------------------
# q. Step 6 CONFIRM_CODE post-action gate
# ---------------------------------------------------------------------------
echo "=== q. Step 6 CONFIRM_CODE post-action gate ==="
if require_file "$WRITE_CODE_SKILL"; then
    hit=$(awk '/Present the final edited file list/{a=NR} a && NR>=a-8 && NR<=a+8 && /CONFIRM_CODE/{print NR; exit}' "$WRITE_CODE_SKILL")
    if [ -n "$hit" ]; then
        pass "Step 6 CONFIRM_CODE gate adjacent to 'Present the final edited file list' (line $hit)"
    else
        fail "Step 6 CONFIRM_CODE gate missing near 'Present the final edited file list'"
    fi
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
