#!/usr/bin/env bash
# Contract tests for design-approach skill (Stage 2: approach-designer + approach-reviewer)
# Target files (expected to FAIL until implementation is complete):
#   $HOME/.claude/skills/design-approach/SKILL.md
#   $HOME/.claude/agents/approach-designer.md
#   $HOME/.claude/agents/approach-reviewer.md
# Exit 0 always — this is a contract test, not a CI gate yet.

# Timeout guard: if running without the sentinel, re-exec under timeout
if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

SKILL_MD="$HOME/.claude/skills/design-approach/SKILL.md"
DESIGNER_MD="$HOME/.claude/agents/approach-designer.md"
REVIEWER_MD="$HOME/.claude/agents/approach-reviewer.md"

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

# assert_contains FILE PATTERN DESCRIPTION
# Greps FILE for PATTERN (extended regex). Prints PASS/FAIL.
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc (pattern not found: $pattern)"
        return 1
    fi
}

# assert_absent FILE PATTERN DESCRIPTION
# Asserts FILE does NOT contain PATTERN. Prints PASS/FAIL.
assert_absent() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc (pattern unexpectedly found: $pattern)"
        return 1
    else
        pass "$desc"
        return 0
    fi
}

echo "=== design-approach contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases — SKILL_MD
# ---------------------------------------------------------------------------
echo "--- Normal (SKILL_MD) ---"

# N1: frontmatter name: design-approach
assert_contains "$SKILL_MD" "name:[[:space:]]*design-approach" \
    "N1: frontmatter contains 'name: design-approach'"

# N2: approach-designer referenced
assert_contains "$SKILL_MD" "approach-designer" \
    "N2: approach-designer referenced in SKILL_MD"

# N3: approach-reviewer referenced
assert_contains "$SKILL_MD" "approach-reviewer" \
    "N3: approach-reviewer referenced in SKILL_MD"

# N4: 2-round max mentioned
assert_contains "$SKILL_MD" "revision_rounds|2.*round|round.*2" \
    "N4: 2-round max mentioned in SKILL_MD"

# N5: <session-id>-approach.md output mentioned
assert_contains "$SKILL_MD" "approach\.md" \
    "N5: approach.md output filename mentioned in SKILL_MD"

# N6: reads intent.md as input
assert_contains "$SKILL_MD" "intent\.md" \
    "N6: intent.md referenced as input in SKILL_MD"

# N7: SINGLE_APPROACH_JUSTIFIED mentioned
assert_contains "$SKILL_MD" "SINGLE_APPROACH_JUSTIFIED" \
    "N7: SINGLE_APPROACH_JUSTIFIED mentioned in SKILL_MD"

echo ""
# ---------------------------------------------------------------------------
# Normal cases — DESIGNER_MD
# ---------------------------------------------------------------------------
echo "--- Normal (DESIGNER_MD) ---"

# N8: frontmatter model: opus
assert_contains "$DESIGNER_MD" "model:[[:space:]]*opus" \
    "N8: DESIGNER_MD frontmatter contains 'model: opus'"

# N9: 2-3 approaches required or mutually exclusive
assert_contains "$DESIGNER_MD" "2.{0,30}3.*approach|mutually.exclusive|相互に排他" \
    "N9: 2-3 approaches required or mutually exclusive stated in DESIGNER_MD"

# N10: file paths prohibited
assert_contains "$DESIGNER_MD" "file path.*禁止|禁止.*file path|do not.*file path|prohibit.*path|[Ss]trictly forbidden|ファイル.*パス.*禁止|禁止.*ファイル.*パス" \
    "N10: file paths prohibited stated in DESIGNER_MD"

# N11: SINGLE_APPROACH_JUSTIFIED defined
assert_contains "$DESIGNER_MD" "SINGLE_APPROACH_JUSTIFIED" \
    "N11: SINGLE_APPROACH_JUSTIFIED defined in DESIGNER_MD"

# N12: NEEDS_RESEARCH escape hatch
assert_contains "$DESIGNER_MD" "NEEDS_RESEARCH" \
    "N12: NEEDS_RESEARCH escape hatch defined in DESIGNER_MD"

# N13: tradeoff per approach
assert_contains "$DESIGNER_MD" "tradeoff|trade.off|トレードオフ" \
    "N13: tradeoff per approach mentioned in DESIGNER_MD"

echo ""
# ---------------------------------------------------------------------------
# Normal cases — REVIEWER_MD
# ---------------------------------------------------------------------------
echo "--- Normal (REVIEWER_MD) ---"

# N14: frontmatter model: opus
assert_contains "$REVIEWER_MD" "model:[[:space:]]*opus" \
    "N14: REVIEWER_MD frontmatter contains 'model: opus'"

# N15: APPROVED verdict
assert_contains "$REVIEWER_MD" "APPROVED" \
    "N15: APPROVED verdict defined in REVIEWER_MD"

# N16: MISSING_ALTERNATIVE verdict
assert_contains "$REVIEWER_MD" "MISSING_ALTERNATIVE" \
    "N16: MISSING_ALTERNATIVE verdict defined in REVIEWER_MD"

# N17: drill-down / file path comment prohibition
assert_contains "$REVIEWER_MD" "drill.down|file path|ファイル.*パス|step.*level|実装.*詳細" \
    "N17: drill-down or file path comment prohibition in REVIEWER_MD"

echo ""
# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
echo "--- Error ---"

# E1: NEEDS_REVISION does NOT appear as a verdict option in REVIEWER_MD;
#     MISSING_ALTERNATIVE is the only non-APPROVED path.
#     Check MISSING_ALTERNATIVE exists (positive) and NEEDS_REVISION is absent (negative).
assert_absent "$REVIEWER_MD" "NEEDS_REVISION" \
    "E1a: NEEDS_REVISION does NOT appear as a verdict in REVIEWER_MD"

assert_contains "$REVIEWER_MD" "MISSING_ALTERNATIVE" \
    "E1b: MISSING_ALTERNATIVE is present as the replacement non-APPROVED verdict in REVIEWER_MD"

echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
echo "--- Edge ---"

# Ed1: SINGLE_APPROACH_JUSTIFIED escape path explicitly defined in DESIGNER_MD
#      (full sentinel string must appear — already N11, expanded check)
if [ ! -f "$DESIGNER_MD" ]; then
    fail "Ed1: SINGLE_APPROACH_JUSTIFIED escape path explicitly defined (file not found: $DESIGNER_MD)"
elif grep -qF "SINGLE_APPROACH_JUSTIFIED" "$DESIGNER_MD"; then
    pass "Ed1: SINGLE_APPROACH_JUSTIFIED full sentinel string appears in DESIGNER_MD"
else
    fail "Ed1: SINGLE_APPROACH_JUSTIFIED full sentinel string must appear in DESIGNER_MD"
fi

# Ed2: REVIEWER_MD has exactly 2 verdict options: APPROVED and MISSING_ALTERNATIVE;
#      no LGTM or NEEDS_REVISION third option.
if [ ! -f "$REVIEWER_MD" ]; then
    fail "Ed2: exactly 2 verdict options in REVIEWER_MD (file not found: $REVIEWER_MD)"
else
    _has_approved=0
    _has_missing_alt=0
    _has_lgtm=0
    _has_needs_revision=0
    grep -qF "APPROVED" "$REVIEWER_MD" && _has_approved=1
    grep -qF "MISSING_ALTERNATIVE" "$REVIEWER_MD" && _has_missing_alt=1
    grep -qE "LGTM" "$REVIEWER_MD" && _has_lgtm=1
    grep -qE "NEEDS_REVISION" "$REVIEWER_MD" && _has_needs_revision=1

    if [ "$_has_approved" -eq 1 ] && [ "$_has_missing_alt" -eq 1 ] && \
       [ "$_has_lgtm" -eq 0 ] && [ "$_has_needs_revision" -eq 0 ]; then
        pass "Ed2: exactly 2 verdict options (APPROVED + MISSING_ALTERNATIVE, no LGTM/NEEDS_REVISION) in REVIEWER_MD"
    else
        fail "Ed2: exactly 2 verdict options check failed (approved=$_has_approved missing_alt=$_has_missing_alt lgtm=$_has_lgtm needs_revision=$_has_needs_revision)"
    fi
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
