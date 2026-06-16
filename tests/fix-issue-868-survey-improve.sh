#!/bin/bash
# Tests: skills/issue-create/SKILL.md
# Tags: issue-create, github, survey, rubric, coverage
# Tests for issue #868: survey coverage and verdict rubric improvements.
#
# L3 gap (what this test does NOT catch):
# - LLM actually applies the rubric correctly when inspecting live candidates
# - Actual gh issue list API calls are made in the described order
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Test cases:
#   VR-1..4  — verdict rubric assertions (regression row, rubric section, symptom rule, tie-break)
#   PC-1..7  — pass configuration assertions (parallel symptom, Pass 2 symptom, Pass 3 widened, inspect cap)
#   SZ-1     — SKILL.md size ≤ 200 lines
#   DF-1..4  — decision-flow behavioral assertions (static grep)
#   REG-661  — regression guard: re-runs feature-661 suite
#
# NOTE: VR, PC, DF, and REG-661 tests will be RED before SKILL.md is updated (expected).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC_SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract Phase 2 section once for reuse
if [ -f "$IC_SKILL_MD" ]; then
    PHASE2=$(awk '/^### Phase 2/,/^### Phase 3/' "$IC_SKILL_MD")
else
    PHASE2=""
fi

# ---------------------------------------------------------------------------
# VR-1: verdict table has regression/recurrence → reopen row with
#        closure-reason-agnostic note
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "VR-1: skills/issue-create/SKILL.md missing"
elif grep -qiE "recurrence|regression" "$IC_SKILL_MD" && grep -qiE "regardless of" "$IC_SKILL_MD"; then
    pass "VR-1: verdict table has regression/recurrence → reopen row with closure-reason-agnostic note"
else
    fail "VR-1: SKILL.md missing 'recurrence|regression' or 'regardless of' — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# VR-2: Phase 2 contains a Verdict Rubric section
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "VR-2: skills/issue-create/SKILL.md missing"
elif grep -qiE "verdict rubric|rubric" "$IC_SKILL_MD"; then
    pass "VR-2: Phase 2 contains a Verdict Rubric section"
else
    fail "VR-2: SKILL.md does not contain a 'rubric' section — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# VR-3: Phase 2 rubric includes symptom-match rule
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "VR-3: skills/issue-create/SKILL.md missing"
elif echo "$PHASE2" | grep -qiE "symptom"; then
    pass "VR-3: Phase 2 rubric includes symptom-match rule"
else
    fail "VR-3: Phase 2 section does not mention 'symptom' in rubric context"
fi

# ---------------------------------------------------------------------------
# VR-4: rubric specifies tie-break order with closed prioritized over open
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "VR-4: skills/issue-create/SKILL.md missing"
elif grep -qiE "tie.?break" "$IC_SKILL_MD"; then
    # Check that 'closed' appears before 'open' somewhere near the tie-break context
    TIE_LINE=$(grep -niE "tie.?break" "$IC_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$TIE_LINE" ]; then
        # Look in a window of 10 lines after the tie-break mention
        WINDOW=$(awk -v start="$TIE_LINE" -v end="$((TIE_LINE + 10))" 'NR>=start && NR<=end' "$IC_SKILL_MD")
        CLOSED_POS=$(echo "$WINDOW" | grep -niE "closed" | head -1 | cut -d: -f1)
        OPEN_POS=$(echo "$WINDOW" | grep -niE "\bopen\b" | head -1 | cut -d: -f1)
        if [ -n "$CLOSED_POS" ] && [ -n "$OPEN_POS" ] && [ "$CLOSED_POS" -le "$OPEN_POS" ]; then
            pass "VR-4: rubric specifies tie-break order with closed prioritized over open"
        else
            fail "VR-4: tie-break found but 'closed' does not precede 'open' in the rubric — RED"
        fi
    else
        fail "VR-4: tie-break mention found but line number resolution failed"
    fi
else
    fail "VR-4: SKILL.md does not contain 'tie-break' — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# PC-1: Pass 1 describes symptom-token search as always running
#        (not fallback-only)
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-1: skills/issue-create/SKILL.md missing"
elif echo "$PHASE2" | grep -qiE "always (also )?run|always run both|parallel|unconditionally"; then
    pass "PC-1: Pass 1 describes symptom-token search as always running (not fallback-only)"
else
    fail "PC-1: Phase 2 does not describe symptom as always-running — RED until parallel search is added"
fi

# ---------------------------------------------------------------------------
# PC-2: Pass 1 has parallel keyword and symptom searches
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-2: skills/issue-create/SKILL.md missing"
else
    # Count occurrences of --state all --limit 50 in Phase 2 — expect 2 for parallel searches
    STATE_ALL_COUNT=$(echo "$PHASE2" | grep -cE "\-\-state all .*\-\-limit 50")
    if [ "$STATE_ALL_COUNT" -ge 2 ]; then
        pass "PC-2: Pass 1 has parallel keyword and symptom searches ($STATE_ALL_COUNT --state all --limit 50 occurrences)"
    elif echo "$PHASE2" | grep -qiE "parallel" && echo "$PHASE2" | grep -qiE "symptom"; then
        pass "PC-2: Pass 1 has parallel keyword and symptom searches (parallel + symptom mentioned)"
    else
        fail "PC-2: Phase 2 does not show two parallel searches — RED ($STATE_ALL_COUNT --state all --limit 50 occurrences found)"
    fi
fi

# ---------------------------------------------------------------------------
# PC-3: Pass 2 has symptom-token open search without date filter
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-3: skills/issue-create/SKILL.md missing"
else
    # Look for Pass 2 followed by --state open with --limit 50 and symptom mention
    PASS2_BLOCK=$(echo "$PHASE2" | awk '/Pass 2/,/Pass 3/')
    if echo "$PASS2_BLOCK" | grep -qE "\-\-state open" \
       && echo "$PASS2_BLOCK" | grep -qE "\-\-limit 50" \
       && echo "$PASS2_BLOCK" | grep -qiE "symptom"; then
        pass "PC-3: Pass 2 has symptom-token open search without date filter"
    else
        fail "PC-3: Pass 2 does not have symptom-token open search with --limit 50 — RED"
    fi
fi

# ---------------------------------------------------------------------------
# PC-4: Pass 3 uses --limit 50 (widened from 30)
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-4: skills/issue-create/SKILL.md missing"
else
    PASS3_BLOCK=$(echo "$PHASE2" | awk '/Pass 3/,/^$/')
    if echo "$PASS3_BLOCK" | grep -qE "\-\-limit 50" \
       && echo "$PASS3_BLOCK" | grep -qE "\-\-state closed"; then
        pass "PC-4: Pass 3 uses --limit 50 (widened from 30)"
    else
        fail "PC-4: Pass 3 does not use --limit 50 with --state closed — RED until widened"
    fi
fi

# ---------------------------------------------------------------------------
# PC-5: Pass 3 includes symptom-token search
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-5: skills/issue-create/SKILL.md missing"
else
    PASS3_BLOCK=$(echo "$PHASE2" | awk '/Pass 3/,/^$/')
    if echo "$PASS3_BLOCK" | grep -qiE "symptom"; then
        pass "PC-5: Pass 3 includes symptom-token search"
    else
        fail "PC-5: Pass 3 does not mention 'symptom' — RED until added"
    fi
fi

# ---------------------------------------------------------------------------
# PC-6: candidate inspection cap is 25
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-6: skills/issue-create/SKILL.md missing"
elif grep -qiE "up to (~)?25|25 (unique|candidates)" "$IC_SKILL_MD"; then
    pass "PC-6: candidate inspection cap is 25"
else
    fail "PC-6: SKILL.md does not mention 'up to 25' or '25 unique/candidates' — RED until widened"
fi

# ---------------------------------------------------------------------------
# PC-7: cross-pass deduplication is mentioned
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "PC-7: skills/issue-create/SKILL.md missing"
elif grep -qiE "dedup|deduplicate|deduplication" "$IC_SKILL_MD"; then
    pass "PC-7: cross-pass deduplication is mentioned"
else
    fail "PC-7: SKILL.md does not mention dedup/deduplicate — RED"
fi

# ---------------------------------------------------------------------------
# SZ-1: SKILL.md size ≤ 200 lines (Pattern B HARD limit)
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "SZ-1: skills/issue-create/SKILL.md missing"
else
    LINE_COUNT=$(wc -l < "$IC_SKILL_MD")
    if [ "$LINE_COUNT" -le 200 ]; then
        pass "SZ-1: SKILL.md has $LINE_COUNT lines (≤ 200 HARD limit)"
    else
        fail "SZ-1: SKILL.md has $LINE_COUNT lines (exceeds 200-line HARD limit)"
    fi
fi

# ---------------------------------------------------------------------------
# DF-1: rubric specifies verdict 'none' for no-match case
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "DF-1: skills/issue-create/SKILL.md missing"
else
    # Look for 'none' near 'no match' or 'unrelated' (within 5 lines)
    if grep -niE "no match|unrelated" "$IC_SKILL_MD" | head -1 > /tmp/df1-pos.txt; then
        NM_LINE=$(cut -d: -f1 /tmp/df1-pos.txt)
        if [ -n "$NM_LINE" ]; then
            WINDOW_START=$((NM_LINE > 5 ? NM_LINE - 5 : 1))
            WINDOW_END=$((NM_LINE + 5))
            WINDOW=$(awk -v s="$WINDOW_START" -v e="$WINDOW_END" 'NR>=s && NR<=e' "$IC_SKILL_MD")
            if echo "$WINDOW" | grep -qiE "\bnone\b"; then
                pass "DF-1: rubric specifies verdict 'none' for no-match case"
            else
                fail "DF-1: 'no match'/'unrelated' found but 'none' verdict not nearby — RED"
            fi
        else
            fail "DF-1: line resolution failed for no-match context"
        fi
    else
        fail "DF-1: SKILL.md does not contain 'no match' or 'unrelated' — RED until rubric is added"
    fi
    rm -f /tmp/df1-pos.txt
fi

# ---------------------------------------------------------------------------
# DF-2: rubric treats age as tie-break not filter
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "DF-2: skills/issue-create/SKILL.md missing"
elif grep -qiE "tie.?break" "$IC_SKILL_MD" && grep -qiE "age|recent|recency" "$IC_SKILL_MD"; then
    # Ensure 'filter' does not appear in proximity to 'age' in rubric
    AGE_LINE=$(grep -niE "\bage\b|recency" "$IC_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$AGE_LINE" ]; then
        WINDOW_START=$((AGE_LINE > 3 ? AGE_LINE - 3 : 1))
        WINDOW_END=$((AGE_LINE + 3))
        WINDOW=$(awk -v s="$WINDOW_START" -v e="$WINDOW_END" 'NR>=s && NR<=e' "$IC_SKILL_MD")
        if echo "$WINDOW" | grep -qiE "filter"; then
            fail "DF-2: 'age' appears in proximity to 'filter' — should be tie-break only"
        else
            pass "DF-2: rubric treats age as tie-break not filter"
        fi
    else
        pass "DF-2: rubric mentions tie-break + recent (no age line to check filter proximity)"
    fi
else
    fail "DF-2: SKILL.md missing tie-break + age/recent — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# DF-3: regression row is closure-reason-agnostic (mentions 'regardless')
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "DF-3: skills/issue-create/SKILL.md missing"
elif echo "$PHASE2" | grep -qiE "regardless"; then
    pass "DF-3: regression row is closure-reason-agnostic (mentions 'regardless')"
else
    fail "DF-3: Phase 2 does not contain 'regardless' — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# DF-4: tie-break order places closed before open
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "DF-4: skills/issue-create/SKILL.md missing"
elif grep -qiE "tie.?break" "$IC_SKILL_MD"; then
    TIE_LINE=$(grep -niE "tie.?break" "$IC_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$TIE_LINE" ]; then
        WINDOW_END=$((TIE_LINE + 15))
        WINDOW=$(awk -v s="$TIE_LINE" -v e="$WINDOW_END" 'NR>=s && NR<=e' "$IC_SKILL_MD")
        CLOSED_LINE=$(echo "$WINDOW" | grep -niE "closed" | head -1 | cut -d: -f1)
        OPEN_LINE=$(echo "$WINDOW" | grep -niE "\bopen\b" | head -1 | cut -d: -f1)
        if [ -n "$CLOSED_LINE" ] && [ -n "$OPEN_LINE" ] && [ "$CLOSED_LINE" -le "$OPEN_LINE" ]; then
            pass "DF-4: tie-break order places closed before open"
        else
            fail "DF-4: tie-break found but 'closed' does not precede 'open' — RED"
        fi
    else
        fail "DF-4: tie-break line resolution failed"
    fi
else
    fail "DF-4: SKILL.md does not contain 'tie-break' — RED until rubric is added"
fi

# ---------------------------------------------------------------------------
# REG-661: regression guard — re-runs feature-661 suite
# Expected RED before SKILL.md edits (IC-FALLBACK-2/-3/-4 currently fail).
# ---------------------------------------------------------------------------
bash "$AGENTS_DIR/tests/feature-661-survey-symptom-fallback.sh" > /tmp/reg661-output.txt 2>&1
RC=$?
if [ $RC -eq 0 ]; then
    pass "REG-661: feature-661 suite all passed"
else
    FAIL661=$(grep "^FAIL:" /tmp/reg661-output.txt | wc -l)
    fail "REG-661: feature-661 suite had $FAIL661 failure(s) — expected RED before SKILL.md edits"
fi
rm -f /tmp/reg661-output.txt

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
