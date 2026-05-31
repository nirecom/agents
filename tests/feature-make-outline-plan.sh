#!/usr/bin/env bash
# Tests: agents/outline-planner.md, agents/outline-reviewer.md, skills/_shared/codex-review-loop.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, sentinel, workflow, skill
# Contract tests for make-outline-plan skill (Stage 2: outline-planner + outline-reviewer)
# Target files (expected to FAIL until implementation is complete):
#   $HOME/.claude/skills/make-outline-plan/SKILL.md
#   $HOME/.claude/agents/outline-planner.md
#   $HOME/.claude/agents/outline-reviewer.md
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

SKILL_MD="$HOME/.claude/skills/make-outline-plan/SKILL.md"
PLANNER_MD="$HOME/.claude/agents/outline-planner.md"
REVIEWER_MD="$HOME/.claude/agents/outline-reviewer.md"

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

echo "=== make-outline-plan contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases — SKILL_MD
# ---------------------------------------------------------------------------
echo "--- Normal (SKILL_MD) ---"

# N1: frontmatter name: make-outline-plan
assert_contains "$SKILL_MD" "name:[[:space:]]*make-outline-plan" \
    "N1: frontmatter contains 'name: make-outline-plan'"

# N2: outline-planner referenced
assert_contains "$SKILL_MD" "outline-planner" \
    "N2: outline-planner referenced in SKILL_MD"

# N3: outline-reviewer referenced
assert_contains "$SKILL_MD" "outline-reviewer" \
    "N3: outline-reviewer referenced in SKILL_MD"

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
# Normal cases — PLANNER_MD
# ---------------------------------------------------------------------------
echo "--- Normal (PLANNER_MD) ---"

# N8: frontmatter model: opus
assert_contains "$PLANNER_MD" "model:[[:space:]]*opus" \
    "N8: PLANNER_MD frontmatter contains 'model: opus'"

# N9: 2-3 approaches required or mutually exclusive
assert_contains "$PLANNER_MD" "2.{0,30}3.*approach|mutually.exclusive|相互に排他" \
    "N9: 2-3 approaches required or mutually exclusive stated in PLANNER_MD"

# N10: file paths prohibited
assert_contains "$PLANNER_MD" "file path.*禁止|禁止.*file path|do not.*file path|prohibit.*path|[Ss]trictly forbidden|ファイル.*パス.*禁止|禁止.*ファイル.*パス" \
    "N10: file paths prohibited stated in PLANNER_MD"

# N11: SINGLE_APPROACH_JUSTIFIED defined
assert_contains "$PLANNER_MD" "SINGLE_APPROACH_JUSTIFIED" \
    "N11: SINGLE_APPROACH_JUSTIFIED defined in PLANNER_MD"

# N12: NEEDS_RESEARCH escape hatch
assert_contains "$PLANNER_MD" "NEEDS_RESEARCH" \
    "N12: NEEDS_RESEARCH escape hatch defined in PLANNER_MD"

# N13: tradeoff per approach
assert_contains "$PLANNER_MD" "tradeoff|trade.off|トレードオフ" \
    "N13: tradeoff per approach mentioned in PLANNER_MD"

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
assert_absent "$REVIEWER_MD" "NEEDS_REVISION" \
    "E1a: NEEDS_REVISION does NOT appear as a verdict in REVIEWER_MD"

assert_contains "$REVIEWER_MD" "MISSING_ALTERNATIVE" \
    "E1b: MISSING_ALTERNATIVE is present as the replacement non-APPROVED verdict in REVIEWER_MD"

echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
echo "--- Edge ---"

# Ed1: SINGLE_APPROACH_JUSTIFIED escape path explicitly defined in PLANNER_MD
if [ ! -f "$PLANNER_MD" ]; then
    fail "Ed1: SINGLE_APPROACH_JUSTIFIED escape path explicitly defined (file not found: $PLANNER_MD)"
elif grep -qF "SINGLE_APPROACH_JUSTIFIED" "$PLANNER_MD"; then
    pass "Ed1: SINGLE_APPROACH_JUSTIFIED full sentinel string appears in PLANNER_MD"
else
    fail "Ed1: SINGLE_APPROACH_JUSTIFIED full sentinel string must appear in PLANNER_MD"
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
# ---------------------------------------------------------------------------
# Issue #329: Accepted Tradeoffs section + carry-over log symmetry
# ---------------------------------------------------------------------------
echo "--- Issue #329 ---"

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_REPO="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
PLANNER_REPO="$AGENTS_ROOT/agents/outline-planner.md"

# #329-1: Accepted Tradeoffs section in SKILL.md
if grep -qF "Accepted Tradeoffs" "$SKILL_REPO" 2>/dev/null; then
    pass "#329-1: 'Accepted Tradeoffs' section present in make-outline-plan/SKILL.md"
else
    fail "#329-1: 'Accepted Tradeoffs' section missing from make-outline-plan/SKILL.md"
fi

# #329-2: Accepted Tradeoffs section in outline-planner.md
if grep -qF "Accepted Tradeoffs" "$PLANNER_REPO" 2>/dev/null; then
    pass "#329-2: 'Accepted Tradeoffs' section present in agents/outline-planner.md"
else
    fail "#329-2: 'Accepted Tradeoffs' section missing from agents/outline-planner.md"
fi

# #329-3: round-log + planner-response trailer mechanism. After the _shared/
# extraction, the SKILL.md references skills/_shared/codex-review-loop.md and
# the shared spec carries the round-log / planner-response wording (SSOT).
SHARED_LOOP="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"
if grep -qF "_shared/codex-review-loop.md" "$SKILL_REPO" 2>/dev/null && \
   grep -qE "round.*log|planner-response" "$SHARED_LOOP" 2>/dev/null; then
    pass "#329-3: SKILL.md references _shared/codex-review-loop.md; shared spec covers round-log / planner-response"
else
    fail "#329-3: SKILL.md must reference _shared/codex-review-loop.md, and shared spec must cover round-log / planner-response"
fi

echo ""
# ---------------------------------------------------------------------------
# Issue #462: assemble-mandatory.sh mechanical injection checks
# ---------------------------------------------------------------------------
echo "--- Issue #462: assemble-mandatory ---"

AGENTS_ROOT_462="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_462="$AGENTS_ROOT_462/skills/make-outline-plan/SKILL.md"

# M10: assemble-mandatory.sh called in SKILL.md
if grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M10: assemble-mandatory.sh referenced in make-outline-plan/SKILL.md"
else
    fail "M10: assemble-mandatory.sh NOT referenced in make-outline-plan/SKILL.md"
fi

# M11: SINGLE_APPROACH_JUSTIFIED path also uses assemble-mandatory.sh
# (Both SINGLE_APPROACH_JUSTIFIED and assemble-mandatory must appear in the same file.)
if grep -q "SINGLE_APPROACH_JUSTIFIED" "$SKILL_462" 2>/dev/null && \
   grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M11: SINGLE_APPROACH_JUSTIFIED path and assemble-mandatory.sh both present in SKILL.md"
else
    fail "M11: SINGLE_APPROACH_JUSTIFIED or assemble-mandatory.sh missing from SKILL.md"
fi

# M12a: planner-side contract present (do not write mandatory sections; authored copies stripped).
# Wording moved away from the direct translation "machine-injected"; the contract — that the
# orchestrator carries these sections and the planner must not write them — must remain.
if grep -qE "[Dd]o NOT (instruct the planner to )?(author|write)|[Dd]o not (instruct the planner to )?(author|write)|planner.authored copies (will be|are) stripped|helper carries them forward" "$SKILL_462" 2>/dev/null; then
    pass "M12a: planner-side 'do not write / authored copies stripped' contract present in make-outline-plan/SKILL.md"
else
    fail "M12a: SKILL.md missing the planner-side contract (do not write mandatory sections / authored copies are stripped)"
fi

# M12b: no verbatim-copy instruction (machine-injection replaces manual copy)
if ! grep -qE "verbatim.copy|copy.*verbatim" "$SKILL_462" 2>/dev/null; then
    pass "M12b: no 'verbatim copy' instruction in make-outline-plan/SKILL.md (machine-injection replaces it)"
else
    fail "M12b: 'verbatim copy' instruction still present in SKILL.md — should be removed"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
