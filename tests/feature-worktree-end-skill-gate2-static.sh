#!/bin/bash
# tests/feature-worktree-end-skill-gate2-static.sh
# Tests: skills/worktree-end/SKILL.md
# Tags: static, skill, worktree-end, gate2, unstaged-tracked
#
# Static contract test for Gate 2 (worktree-end pre-flight).
# Expected red until #269 lands Step WE-2.5 in skills/worktree-end/SKILL.md.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="${AGENTS_DIR}/skills/worktree-end/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL_MD" ]; then
    fail "skills/worktree-end/SKILL.md not present" "$SKILL_MD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit $FAIL
fi

# Helper: line number (or empty) of the first occurrence of a fixed-string pattern.
line_of() {
    grep -nF "$1" "$SKILL_MD" 2>/dev/null | head -n 1 | cut -d: -f1
}

# Test 1: ### Step WE-2.5 heading exists
test_1_we25_heading() {
    if grep -qE '^### Step WE-2\.5' "$SKILL_MD"; then
        pass "1: ### Step WE-2.5 heading exists"
    else
        fail "1: missing '### Step WE-2.5' heading"
    fi
}

# Test 2: bin/check-unstaged-tracked.sh appears in WE-2.5 section
test_2_cli_literal_in_we25_section() {
    local we25_line next_step_line cli_line
    we25_line="$(grep -nE '^### Step WE-2\.5' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$we25_line" ]; then
        fail "2: cannot locate ### Step WE-2.5"
        return
    fi
    # Next heading line that begins with '### Step ' and is strictly after WE-2.5.
    next_step_line="$(awk -v L="$we25_line" '/^### Step /{ if (NR > L) { print NR; exit } }' "$SKILL_MD")"
    if [ -z "$next_step_line" ]; then
        # No subsequent step heading — treat end-of-file as boundary
        next_step_line="$(wc -l < "$SKILL_MD" | tr -d ' ')"
    fi
    cli_line="$(grep -nF 'bin/check-unstaged-tracked.sh' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$cli_line" ]; then
        fail "2: bin/check-unstaged-tracked.sh literal not in file"
        return
    fi
    if [ "$cli_line" -gt "$we25_line" ] && [ "$cli_line" -lt "$next_step_line" ]; then
        pass "2: bin/check-unstaged-tracked.sh appears within WE-2.5 section"
    else
        fail "2: bin/check-unstaged-tracked.sh outside WE-2.5 section" \
            "we25=$we25_line cli=$cli_line next_step=$next_step_line"
    fi
}

# Test 3: WE-2.5 section mentions BOTH WORKFLOW_OFF and WORKTREE_OFF
test_3_both_off_modes_in_we25() {
    local we25_line next_step_line section
    we25_line="$(grep -nE '^### Step WE-2\.5' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$we25_line" ]; then
        fail "3: cannot locate ### Step WE-2.5"
        return
    fi
    next_step_line="$(awk -v L="$we25_line" '/^### Step /{ if (NR > L) { print NR; exit } }' "$SKILL_MD")"
    if [ -z "$next_step_line" ]; then
        next_step_line="$(wc -l < "$SKILL_MD" | tr -d ' ')"
    fi
    section="$(awk -v A="$we25_line" -v B="$next_step_line" 'NR>=A && NR<B' "$SKILL_MD")"
    if echo "$section" | grep -q 'WORKFLOW_OFF' && echo "$section" | grep -q 'WORKTREE_OFF'; then
        pass "3: WE-2.5 mentions both WORKFLOW_OFF and WORKTREE_OFF"
    else
        fail "3: WE-2.5 must mention BOTH WORKFLOW_OFF and WORKTREE_OFF"
    fi
}

# Test 4: ## Rules section contains the literal honor-line
test_4_rules_honor_line() {
    # Locate the start of ## Rules
    local rules_line
    rules_line="$(grep -nE '^## Rules' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$rules_line" ]; then
        fail "4: cannot locate ## Rules section"
        return
    fi
    local total
    total="$(wc -l < "$SKILL_MD" | tr -d ' ')"
    local section
    section="$(awk -v A="$rules_line" -v B="$total" 'NR>=A && NR<=B' "$SKILL_MD")"
    if echo "$section" | grep -qF 'Step WE-2.5 honors WORKFLOW_OFF / WORKTREE_OFF'; then
        pass "4: ## Rules contains 'Step WE-2.5 honors WORKFLOW_OFF / WORKTREE_OFF'"
    else
        fail "4: ## Rules missing honor line for WE-2.5"
    fi
}

# Test 5: WE-2.5 heading is between WE-2 and WE-3 (line-number ordering)
test_5_ordering() {
    local l2 l25 l3
    l2="$(grep -nE '^### Step WE-2( |$|—)' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    l25="$(grep -nE '^### Step WE-2\.5' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    l3="$(grep -nE '^### Step WE-3( |$|—)' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$l2" ] || [ -z "$l25" ] || [ -z "$l3" ]; then
        fail "5: missing WE-2 / WE-2.5 / WE-3 heading" "l2=$l2 l25=$l25 l3=$l3"
        return
    fi
    if [ "$l2" -lt "$l25" ] && [ "$l25" -lt "$l3" ]; then
        pass "5: WE-2.5 positioned between WE-2 and WE-3"
    else
        fail "5: ordering wrong" "l2=$l2 l25=$l25 l3=$l3"
    fi
}

run_all() {
    test_1_we25_heading
    test_2_cli_literal_in_we25_section
    test_3_both_off_modes_in_we25
    test_4_rules_honor_line
    test_5_ordering
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
