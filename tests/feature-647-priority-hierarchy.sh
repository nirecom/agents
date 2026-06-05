#!/usr/bin/env bash
# Tests: skills/_shared/priority-hierarchy.md, agents/outline-planner.md, agents/outline-reviewer.md, agents/detail-planner.md, agents/detail-reviewer.md, skills/make-detail-plan/SKILL.md
# Tags: priority-hierarchy, planning, ssot, detail, outline, reject-disposition
# Static checks for issue #647 — priority-hierarchy SSOT.
#
# Verifies:
#   1. SSOT file exists at skills/_shared/priority-hierarchy.md
#   2–6. Required section headings present in SSOT
#   7. Literal ranking string present
#   8. Literal rejection token present
#   9. SSOT line count ≤50
#   10–14. Each consumer file references the SSOT path
#   15–16. reject: contradicts approved within 15 lines of ROUND_RESPONSE in planners
#   17. detail-planner.md contains ## Approved Scope & Priority Hierarchy heading
#
# Tests FAIL until implementation is complete — that is expected.
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

SSOT="$AGENTS_WORKTREE/skills/_shared/priority-hierarchy.md"
OUTLINE_PLANNER="$AGENTS_WORKTREE/agents/outline-planner.md"
OUTLINE_REVIEWER="$AGENTS_WORKTREE/agents/outline-reviewer.md"
DETAIL_PLANNER="$AGENTS_WORKTREE/agents/detail-planner.md"
DETAIL_REVIEWER="$AGENTS_WORKTREE/agents/detail-reviewer.md"
DETAIL_SKILL="$AGENTS_WORKTREE/skills/make-detail-plan/SKILL.md"

echo "=== feature-647: priority-hierarchy SSOT ==="
echo ""

# ---------------------------------------------------------------------------
# 1. SSOT file exists
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ]; then
    pass "1: SSOT file skills/_shared/priority-hierarchy.md exists"
else
    fail "1: SSOT file skills/_shared/priority-hierarchy.md does not exist"
fi

# ---------------------------------------------------------------------------
# 2. SSOT contains heading: ## Ranking (most authoritative first)
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "## Ranking (most authoritative first)" "$SSOT"; then
    pass "2: SSOT contains heading '## Ranking (most authoritative first)'"
else
    fail "2: SSOT missing heading '## Ranking (most authoritative first)'"
fi

# ---------------------------------------------------------------------------
# 3. SSOT contains heading: ## Stage-conditional scope
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "## Stage-conditional scope" "$SSOT"; then
    pass "3: SSOT contains heading '## Stage-conditional scope'"
else
    fail "3: SSOT missing heading '## Stage-conditional scope'"
fi

# ---------------------------------------------------------------------------
# 4. SSOT contains heading: ## Planner rejection protocol
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "## Planner rejection protocol" "$SSOT"; then
    pass "4: SSOT contains heading '## Planner rejection protocol'"
else
    fail "4: SSOT missing heading '## Planner rejection protocol'"
fi

# ---------------------------------------------------------------------------
# 5. SSOT contains heading: ## Reviewer self-check
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "## Reviewer self-check" "$SSOT"; then
    pass "5: SSOT contains heading '## Reviewer self-check'"
else
    fail "5: SSOT missing heading '## Reviewer self-check'"
fi

# ---------------------------------------------------------------------------
# 6. SSOT contains heading: ## Out of scope
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "## Out of scope" "$SSOT"; then
    pass "6: SSOT contains heading '## Out of scope'"
else
    fail "6: SSOT missing heading '## Out of scope'"
fi

# ---------------------------------------------------------------------------
# 7. SSOT contains literal ranking string
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "intent.md > outline.md > detail-draft.md" "$SSOT"; then
    pass "7: SSOT contains 'intent.md > outline.md > detail-draft.md'"
else
    fail "7: SSOT missing 'intent.md > outline.md > detail-draft.md'"
fi

# ---------------------------------------------------------------------------
# 8. SSOT contains literal rejection token
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ] && grep -qF "reject: contradicts approved" "$SSOT"; then
    pass "8: SSOT contains 'reject: contradicts approved'"
else
    fail "8: SSOT missing 'reject: contradicts approved'"
fi

# ---------------------------------------------------------------------------
# 9. SSOT is ≤50 lines
# ---------------------------------------------------------------------------
if [ -f "$SSOT" ]; then
    LINE_COUNT=$(wc -l < "$SSOT")
    if [ "$LINE_COUNT" -le 50 ]; then
        pass "9: SSOT is ≤50 lines (actual: $LINE_COUNT)"
    else
        fail "9: SSOT exceeds 50 lines (actual: $LINE_COUNT)"
    fi
else
    fail "9: SSOT file missing — cannot check line count"
fi

# ---------------------------------------------------------------------------
# 10. agents/outline-planner.md references the SSOT path
# ---------------------------------------------------------------------------
if [ -f "$OUTLINE_PLANNER" ] && grep -qF "skills/_shared/priority-hierarchy.md" "$OUTLINE_PLANNER"; then
    pass "10: agents/outline-planner.md references skills/_shared/priority-hierarchy.md"
else
    fail "10: agents/outline-planner.md does not reference skills/_shared/priority-hierarchy.md"
fi

# ---------------------------------------------------------------------------
# 11. agents/outline-reviewer.md references the SSOT path
# ---------------------------------------------------------------------------
if [ -f "$OUTLINE_REVIEWER" ] && grep -qF "skills/_shared/priority-hierarchy.md" "$OUTLINE_REVIEWER"; then
    pass "11: agents/outline-reviewer.md references skills/_shared/priority-hierarchy.md"
else
    fail "11: agents/outline-reviewer.md does not reference skills/_shared/priority-hierarchy.md"
fi

# ---------------------------------------------------------------------------
# 12. agents/detail-planner.md references the SSOT path
# ---------------------------------------------------------------------------
if [ -f "$DETAIL_PLANNER" ] && grep -qF "skills/_shared/priority-hierarchy.md" "$DETAIL_PLANNER"; then
    pass "12: agents/detail-planner.md references skills/_shared/priority-hierarchy.md"
else
    fail "12: agents/detail-planner.md does not reference skills/_shared/priority-hierarchy.md"
fi

# ---------------------------------------------------------------------------
# 13. agents/detail-reviewer.md references the SSOT path
# ---------------------------------------------------------------------------
if [ -f "$DETAIL_REVIEWER" ] && grep -qF "skills/_shared/priority-hierarchy.md" "$DETAIL_REVIEWER"; then
    pass "13: agents/detail-reviewer.md references skills/_shared/priority-hierarchy.md"
else
    fail "13: agents/detail-reviewer.md does not reference skills/_shared/priority-hierarchy.md"
fi

# ---------------------------------------------------------------------------
# 14. skills/make-detail-plan/SKILL.md references the SSOT path
# ---------------------------------------------------------------------------
if [ -f "$DETAIL_SKILL" ] && grep -qF "skills/_shared/priority-hierarchy.md" "$DETAIL_SKILL"; then
    pass "14: skills/make-detail-plan/SKILL.md references skills/_shared/priority-hierarchy.md"
else
    fail "14: skills/make-detail-plan/SKILL.md does not reference skills/_shared/priority-hierarchy.md"
fi

# ---------------------------------------------------------------------------
# Helper: check that STRING appears within WINDOW lines before/after ANCHOR
# in FILE. Returns 0 if found, 1 otherwise.
# Usage: within_lines_of FILE ANCHOR STRING WINDOW
# ---------------------------------------------------------------------------
within_lines_of() {
    local file="$1"
    local anchor="$2"
    local needle="$3"
    local window="$4"

    if [ ! -f "$file" ]; then
        return 1
    fi

    # Find the line number of the first occurrence of ANCHOR
    local anchor_line
    anchor_line=$(awk "/$anchor/ { print NR; exit }" "$file")
    if [ -z "$anchor_line" ]; then
        return 1
    fi

    local low=$(( anchor_line - window ))
    local high=$(( anchor_line + window ))
    [ "$low" -lt 1 ] && low=1

    # Check if needle appears in that range
    awk "NR >= $low && NR <= $high && /$needle/ { found=1 } END { exit !found }" "$file"
}

# ---------------------------------------------------------------------------
# 15. agents/outline-planner.md: reject: contradicts approved within 15 lines
#     of ROUND_RESPONSE
# ---------------------------------------------------------------------------
if [ -f "$OUTLINE_PLANNER" ]; then
    if within_lines_of "$OUTLINE_PLANNER" "ROUND_RESPONSE" "reject: contradicts approved" 15; then
        pass "15: outline-planner.md has 'reject: contradicts approved' within 15 lines of ROUND_RESPONSE"
    else
        fail "15: outline-planner.md missing 'reject: contradicts approved' within 15 lines of ROUND_RESPONSE"
    fi
else
    fail "15: agents/outline-planner.md not found"
fi

# ---------------------------------------------------------------------------
# 16. agents/detail-planner.md: reject: contradicts approved within 15 lines
#     of ROUND_RESPONSE
# ---------------------------------------------------------------------------
if [ -f "$DETAIL_PLANNER" ]; then
    if within_lines_of "$DETAIL_PLANNER" "ROUND_RESPONSE" "reject: contradicts approved" 15; then
        pass "16: detail-planner.md has 'reject: contradicts approved' within 15 lines of ROUND_RESPONSE"
    else
        fail "16: detail-planner.md missing 'reject: contradicts approved' within 15 lines of ROUND_RESPONSE"
    fi
else
    fail "16: agents/detail-planner.md not found"
fi

# ---------------------------------------------------------------------------
# 17. agents/detail-planner.md contains heading ## Approved Scope & Priority Hierarchy
# ---------------------------------------------------------------------------
if [ -f "$DETAIL_PLANNER" ] && grep -qF "## Approved Scope & Priority Hierarchy" "$DETAIL_PLANNER"; then
    pass "17: detail-planner.md contains '## Approved Scope & Priority Hierarchy'"
else
    fail "17: detail-planner.md missing '## Approved Scope & Priority Hierarchy'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
