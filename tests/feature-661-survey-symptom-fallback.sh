#!/bin/bash
# Tests for issue #661: symptom-based fallback in issue-create Phase 2 and survey-history.
#
# Covers:
#   IC-FALLBACK-1..5  — issue-create SKILL.md Phase 2 symptom keyword fallback
#   SH-FALLBACK-1..2  — survey-history SKILL.md zero-results symptom fallback
#   REG-D6            — issue-create SKILL.md regression: Survey/Verdict/Confirm present
#
# RED tests (expect FAIL until implementation):
#   IC-FALLBACK-1, IC-FALLBACK-3, IC-FALLBACK-4, SH-FALLBACK-1
#
# GREEN tests (already pass in current implementation):
#   IC-FALLBACK-2, IC-FALLBACK-5, SH-FALLBACK-2, REG-D6

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC_SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"
SH_SKILL_MD="$AGENTS_DIR/skills/survey-history/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# IC-FALLBACK-1 (Normal): issue-create SKILL.md Phase 2 に "symptom" キーワードが存在する
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "IC-FALLBACK-1: skills/issue-create/SKILL.md missing"
elif grep -qi "symptom" "$IC_SKILL_MD"; then
    pass "IC-FALLBACK-1: issue-create SKILL.md Phase 2 contains 'symptom' keyword"
else
    fail "IC-FALLBACK-1: issue-create SKILL.md does not contain 'symptom' — RED until Phase 2 symptom fallback is implemented"
fi

# ---------------------------------------------------------------------------
# IC-FALLBACK-2 (Normal): issue-create SKILL.md Phase 2 のフォールバックが
# 最初のゼロ件時でトリガーされる記述がある
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "IC-FALLBACK-2: skills/issue-create/SKILL.md missing"
elif grep -q "Zero results" "$IC_SKILL_MD" && grep -q "drop most specific" "$IC_SKILL_MD"; then
    pass "IC-FALLBACK-2: issue-create SKILL.md Phase 2 documents zero-results fallback trigger"
else
    fail "IC-FALLBACK-2: issue-create SKILL.md missing zero-results fallback description"
fi

# ---------------------------------------------------------------------------
# IC-FALLBACK-3 (Normal): issue-create SKILL.md Phase 2 がフォールバック元として
# "Background" または "Changes" を参照している
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "IC-FALLBACK-3: skills/issue-create/SKILL.md missing"
else
    # Extract Phase 2 section (from "### Phase 2" to "### Phase 3")
    PHASE2=$(awk '/^### Phase 2/,/^### Phase 3/' "$IC_SKILL_MD")
    if echo "$PHASE2" | grep -qiE "Background|Changes"; then
        pass "IC-FALLBACK-3: issue-create SKILL.md Phase 2 references Background or Changes as fallback source"
    else
        fail "IC-FALLBACK-3: issue-create SKILL.md Phase 2 does not reference Background or Changes — RED until symptom fallback is added"
    fi
fi

# ---------------------------------------------------------------------------
# IC-FALLBACK-4 (Normal): issue-create SKILL.md で symptom フォールバック記述が
# "drop most specific" より前に現れる
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "IC-FALLBACK-4: skills/issue-create/SKILL.md missing"
else
    SYMPTOM_LINE=$(grep -n "symptom" "$IC_SKILL_MD" | head -1 | cut -d: -f1)
    DROP_LINE=$(grep -n "drop most specific" "$IC_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -z "$SYMPTOM_LINE" ]; then
        fail "IC-FALLBACK-4: 'symptom' not found in issue-create SKILL.md — RED until Phase 2 symptom fallback is implemented"
    elif [ -z "$DROP_LINE" ]; then
        fail "IC-FALLBACK-4: 'drop most specific' not found in issue-create SKILL.md"
    elif [ "$SYMPTOM_LINE" -lt "$DROP_LINE" ]; then
        pass "IC-FALLBACK-4: symptom fallback (line $SYMPTOM_LINE) appears before 'drop most specific' (line $DROP_LINE)"
    else
        fail "IC-FALLBACK-4: symptom fallback (line $SYMPTOM_LINE) does not appear before 'drop most specific' (line $DROP_LINE)"
    fi
fi

# ---------------------------------------------------------------------------
# IC-FALLBACK-5 (Normal): issue-create SKILL.md フォールバックのトークン数が
# 3–5 個に言及している
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "IC-FALLBACK-5: skills/issue-create/SKILL.md missing"
elif grep -qE "3.{1,3}5 (significant )?tokens" "$IC_SKILL_MD"; then
    pass "IC-FALLBACK-5: issue-create SKILL.md mentions 3-5 tokens for keyword extraction"
else
    fail "IC-FALLBACK-5: issue-create SKILL.md does not mention 3-5 tokens"
fi

# ---------------------------------------------------------------------------
# SH-FALLBACK-1 (Normal): survey-history SKILL.md がゼロ件時の symptom フォールバックを記述している
# ---------------------------------------------------------------------------
if [ ! -f "$SH_SKILL_MD" ]; then
    fail "SH-FALLBACK-1: skills/survey-history/SKILL.md missing"
elif grep -qi "symptom" "$SH_SKILL_MD"; then
    pass "SH-FALLBACK-1: survey-history SKILL.md documents zero-results symptom fallback"
else
    fail "SH-FALLBACK-1: survey-history SKILL.md does not mention 'symptom' — RED until zero-results symptom fallback is added"
fi

# ---------------------------------------------------------------------------
# SH-FALLBACK-2 (Normal): survey-history SKILL.md のフォールバック元として
# "User initial prompt" または "issue body" が明示されている
# ("Background/Changes" のみを参照していない)
# ---------------------------------------------------------------------------
if [ ! -f "$SH_SKILL_MD" ]; then
    fail "SH-FALLBACK-2: skills/survey-history/SKILL.md missing"
elif grep -qiE "User initial prompt|issue body" "$SH_SKILL_MD"; then
    pass "SH-FALLBACK-2: survey-history SKILL.md explicitly mentions 'User initial prompt' or 'issue body' as fallback source"
else
    fail "SH-FALLBACK-2: survey-history SKILL.md does not mention 'User initial prompt' or 'issue body' as fallback source"
fi

# ---------------------------------------------------------------------------
# REG-D6 (Regression): issue-create SKILL.md に "Survey", "Verdict", "Confirm" が存在する
# ---------------------------------------------------------------------------
if [ ! -f "$IC_SKILL_MD" ]; then
    fail "REG-D6: skills/issue-create/SKILL.md missing"
elif grep -qi "survey" "$IC_SKILL_MD" && grep -qi "verdict" "$IC_SKILL_MD" && grep -qi "confirm" "$IC_SKILL_MD"; then
    pass "REG-D6: issue-create SKILL.md contains Survey, Verdict, and Confirm (case-insensitive)"
else
    fail "REG-D6: issue-create SKILL.md missing one or more of Survey/Verdict/Confirm"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
