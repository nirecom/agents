#!/bin/bash
# Tests: skills/_shared/judge-task-complexity.md, skills/write-code/SKILL.md, CLAUDE.md, .env.example, rules/coding/python.md, rules/coding/nodejs.md
# Tags: skill, bin, env, config, tests, scope:common
# Static grep-based checks for the /write-code skill implementation: SKILL.md
# content, CLAUDE.md's write-code step docs, .env.example's CONFIRM_CODE, and
# module-system SSOT (rules/coding/nodejs.md is canonical; SKILL.md must not
# duplicate it). Pre-implementation: assertions may FAIL until the skill is
# implemented; the script does not abort on individual assertion failures.
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
# c. SKILL.md gates on CONFIRM_CODE via bin/confirm-off (get-config-var
#    --is-off was retired repo-wide in favor of bin/confirm-off; #1002)
# ---------------------------------------------------------------------------
echo "=== c. SKILL.md contains bin/confirm-off CONFIRM_CODE gate ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "bin/confirm-off\" CONFIRM_CODE" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'bin/confirm-off\" CONFIRM_CODE'"
    else
        fail "SKILL.md missing 'bin/confirm-off\" CONFIRM_CODE' gate"
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

# ---------------------------------------------------------------------------
# k. rules/coding/python.md retains paths: frontmatter
# ---------------------------------------------------------------------------
echo "=== k. rules/coding/python.md has paths: frontmatter ==="
if require_file "$PYTHON_RULES"; then
    if head -10 "$PYTHON_RULES" | grep -F "paths:" >/dev/null 2>&1; then
        pass "rules/coding/python.md retains 'paths:' frontmatter"
    else
        fail "rules/coding/python.md missing 'paths:' in first 10 lines"
    fi
fi

# ---------------------------------------------------------------------------
# l. rules/coding/nodejs.md retains paths: frontmatter
# ---------------------------------------------------------------------------
echo "=== l. rules/coding/nodejs.md has paths: frontmatter ==="
if require_file "$NODEJS_RULES"; then
    if head -10 "$NODEJS_RULES" | grep -F "paths:" >/dev/null 2>&1; then
        pass "rules/coding/nodejs.md retains 'paths:' frontmatter"
    else
        fail "rules/coding/nodejs.md missing 'paths:' in first 10 lines"
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
# WCD-READ-1: SKILL.md invokes read-session-facts (#2102 bundled reader)
# ---------------------------------------------------------------------------
echo "=== WCD-READ-1: SKILL.md invokes read-session-facts ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "read-session-facts" "$WRITE_CODE_SKILL"; then
        pass "WCD-READ-1. SKILL.md contains 'read-session-facts'"
    else
        fail "WCD-READ-1. SKILL.md missing 'read-session-facts'"
    fi
fi

# ---------------------------------------------------------------------------
# WCD-READ-2: read-session-facts precedes judge-task-complexity (WCD-0's
# bundled read happens before the manual signal-judgment fallback is read)
# ---------------------------------------------------------------------------
echo "=== WCD-READ-2: read-session-facts precedes judge-task-complexity ==="
if require_file "$WRITE_CODE_SKILL"; then
    line_read=$(grep -n "read-session-facts" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_judge=$(grep -n "judge-task-complexity" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_read" ] || [ -z "$line_judge" ]; then
        fail "WCD-READ-2. could not find both anchors (read-session-facts=$line_read, judge-task-complexity=$line_judge)"
    elif [ "$line_read" -lt "$line_judge" ]; then
        pass "WCD-READ-2. read-session-facts (L$line_read) precedes judge-task-complexity (L$line_judge)"
    else
        fail "WCD-READ-2. ordering wrong: read-session-facts=L$line_read, judge-task-complexity=L$line_judge (expected read first)"
    fi
fi

# ---------------------------------------------------------------------------
# r. WCD-2 GATE_CONFIRM_CODE verdict table: OFF proceeds, ON and ERROR both
#    ask — an ERROR verdict silently proceeding would be a fail-open gate.
# ---------------------------------------------------------------------------
echo "=== r. WCD-2 GATE_CONFIRM_CODE verdict table ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd2_section=$(sed -n '/^WCD-2\./,/^WCD-3\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd2_section" ]; then
        fail "r. WCD-2 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd2_section" | grep -qF '`OFF`: proceed to step WCD-3'; then
            pass "r. WCD-2: 'OFF' verdict proceeds without asking"
        else
            fail "r. WCD-2: 'OFF' verdict does not document proceeding to WCD-3"
        fi
        if printf '%s\n' "$wcd2_section" | grep -qF '`ON` or `ERROR`: present the planned edits via `AskUserQuestion`'; then
            pass "r. WCD-2: 'ON' and 'ERROR' verdicts both route to AskUserQuestion (no silent fail-open)"
        else
            fail "r. WCD-2: 'ON'/'ERROR' verdicts do not both route to AskUserQuestion — possible fail-open"
        fi
        # A copy-paste slip from write-tests/SKILL.md's near-identical WT-4 gate
        # (which branches on GATE_CONFIRM_TESTS) would still pass every check
        # above — pin the exact gate key WCD-2 branches on, and that its sibling
        # gate key never leaks into this section.
        if printf '%s\n' "$wcd2_section" | grep -qF 'branch on `GATE_CONFIRM_CODE`'; then
            pass "s. WCD-2: branches on the exact key 'GATE_CONFIRM_CODE'"
        else
            fail "s. WCD-2: does not branch on 'GATE_CONFIRM_CODE' verbatim"
        fi
        if printf '%s\n' "$wcd2_section" | grep -qF 'GATE_CONFIRM_TESTS'; then
            fail "s. WCD-2: leaks the sibling gate key 'GATE_CONFIRM_TESTS' (copy-paste from write-tests)"
        else
            pass "s. WCD-2: does not leak the sibling gate key 'GATE_CONFIRM_TESTS'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# t. WCD-3 consumes the write_code-specific session-facts keys, not the
#    write-tests sibling's keys (a wrong-key copy-paste from write-tests/
#    SKILL.md's WT-5 would still pass every prior check in this file).
# ---------------------------------------------------------------------------
echo "=== t. WCD-3 consumes COMPLEXITY_LEVEL_write_code / COMPLEXITY_SIGNALS ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd3_section=$(sed -n '/^WCD-3\./,/^WCD-3a\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd3_section" ]; then
        fail "t. WCD-3 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd3_section" | grep -qF 'COMPLEXITY_LEVEL_write_code'; then
            pass "t. WCD-3 names 'COMPLEXITY_LEVEL_write_code'"
        else
            fail "t. WCD-3 does not name 'COMPLEXITY_LEVEL_write_code'"
        fi
        if printf '%s\n' "$wcd3_section" | grep -qF 'COMPLEXITY_SIGNALS'; then
            pass "t. WCD-3 names 'COMPLEXITY_SIGNALS'"
        else
            fail "t. WCD-3 does not name 'COMPLEXITY_SIGNALS'"
        fi
        if printf '%s\n' "$wcd3_section" | grep -qF 'COMPLEXITY_LEVEL_write_tests'; then
            fail "t. WCD-3 leaks the sibling key 'COMPLEXITY_LEVEL_write_tests' (copy-paste from write-tests)"
        else
            pass "t. WCD-3 does not leak the sibling key 'COMPLEXITY_LEVEL_write_tests'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# u. WCD-0 fail-closed contract on PLANS_DIR: halt (never construct a path)
#    on a non-zero exit or PLANS_DIR=NONE, and this halt is documented before
#    WCD-2/WCD-3 so it actually gates them rather than being dead prose.
# ---------------------------------------------------------------------------
echo "=== u. WCD-0 PLANS_DIR fail-closed contract precedes WCD-2/WCD-3 ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd0_section=$(sed -n '/^WCD-0\./,/^WCD-1\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd0_section" ]; then
        fail "u. WCD-0 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd0_section" | grep -qF 'PLANS_DIR=NONE'; then
            pass "u. WCD-0 names the 'PLANS_DIR=NONE' halt condition"
        else
            fail "u. WCD-0 does not name the 'PLANS_DIR=NONE' halt condition"
        fi
        if printf '%s\n' "$wcd0_section" | grep -qF 'never construct a path like `NONE/<session-id>-...`'; then
            pass "u. WCD-0 forbids constructing a path from the unresolved PLANS_DIR"
        else
            fail "u. WCD-0 does not forbid constructing a path from the unresolved PLANS_DIR"
        fi
    fi
    line_halt=$(grep -n 'PLANS_DIR=NONE' "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_wcd2=$(grep -n '^WCD-2\.' "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_halt" ] || [ -z "$line_wcd2" ]; then
        fail "u. could not find both anchors (PLANS_DIR=NONE=$line_halt, WCD-2=$line_wcd2)"
    elif [ "$line_halt" -lt "$line_wcd2" ]; then
        pass "u. PLANS_DIR=NONE halt (L$line_halt) precedes WCD-2 (L$line_wcd2)"
    else
        fail "u. ordering wrong: PLANS_DIR=NONE halt=L$line_halt, WCD-2=L$line_wcd2 (expected halt documented first)"
    fi
fi
echo "=== v. WCD-2/WCD-0 gate has real runtime coverage, not just static text ==="
# This file is static-only by design (its own name says so) — it cannot afford
# the session/config fixture that a real GATE_CONFIRM_CODE ON/OFF/ERROR run
# needs (tests/feature-2102-session-facts/values.sh already pays that cost).
# What it CAN and must check: that the CLI WCD-0 tells the orchestrator to run
# is the exact CLI whose runtime output values.sh pins — so a rename here can't
# silently orphan that coverage and leave WCD-2's branch untested end-to-end.
READ_SESSION_FACTS_BIN="$REPO_ROOT/bin/workflow/read-session-facts"
RUNTIME_GATE_TEST="$REPO_ROOT/tests/feature-2102-session-facts/values.sh"
if require_file "$WRITE_CODE_SKILL" && require_file "$RUNTIME_GATE_TEST"; then
    if has_fixed "bin/workflow/read-session-facts" "$WRITE_CODE_SKILL"; then
        pass "v. WCD-0 names bin/workflow/read-session-facts as the runtime source of GATE_CONFIRM_CODE"
    else
        fail "v. WCD-0 does not name bin/workflow/read-session-facts"
    fi
    if [ -f "$READ_SESSION_FACTS_BIN" ]; then
        pass "v. the CLI WCD-0 names actually exists at bin/workflow/read-session-facts"
    else
        fail "v. bin/workflow/read-session-facts does not exist — WCD-0 documents a dead command"
    fi
    if has_fixed "GATE_CONFIRM_CODE" "$RUNTIME_GATE_TEST"; then
        pass "v. tests/feature-2102-session-facts/values.sh pins GATE_CONFIRM_CODE's runtime ON/OFF/ERROR values — the CLI's behavior is exercised, not just this file's prose"
    else
        fail "v. tests/feature-2102-session-facts/values.sh no longer pins GATE_CONFIRM_CODE — the runtime side of WCD-2's gate has no coverage anywhere"
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
