#!/usr/bin/env bash
# Contract tests for make-plan research escalation feature
# Target files (expected to FAIL until implementation is complete):
#   $HOME/.claude/skills/make-plan/SKILL.md
#   $HOME/.claude/agents/planner.md
#   $HOME/.claude/agents/reviewer.md
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

SKILL_MD="$HOME/.claude/skills/make-plan/SKILL.md"
PLANNER_MD="$HOME/.claude/agents/planner.md"
REVIEWER_MD="$HOME/.claude/agents/reviewer.md"

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

echo "=== make-plan research escalation contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases
# ---------------------------------------------------------------------------
echo "--- Normal ---"

# N1: SKILL_MD checks
assert_contains "$SKILL_MD" "NEEDS_RESEARCH" \
    "N1a: SKILL_MD contains literal NEEDS_RESEARCH"

assert_contains "$SKILL_MD" "skill:" \
    "N1b: SKILL_MD contains 'skill:'"

assert_contains "$PLANNER_MD" "question:" \
    "N1c: PLANNER_MD contains 'question:' (format spec lives in planner.md)"

assert_contains "$PLANNER_MD" "reason:" \
    "N1d: PLANNER_MD contains 'reason:' (format spec lives in planner.md)"

assert_contains "$SKILL_MD" "deep-research" \
    "N1e: SKILL_MD contains 'deep-research'"

assert_contains "$SKILL_MD" "Research complete" \
    "N1f: SKILL_MD contains 'Research complete'"

# N2: PLANNER_MD checks
assert_contains "$PLANNER_MD" "NEEDS_RESEARCH" \
    "N2a: PLANNER_MD contains NEEDS_RESEARCH"

assert_contains "$PLANNER_MD" '\[research:' \
    "N2b: PLANNER_MD contains '[research:'"

assert_contains "$PLANNER_MD" "Research Findings \(from this session\)" \
    "N2c: PLANNER_MD contains 'Research Findings (from this session)'"

# N3: Cross-file consistency checks

# N3a: all three files contain NEEDS_RESEARCH
if grep -qE "NEEDS_RESEARCH" "$SKILL_MD" 2>/dev/null && \
   grep -qE "NEEDS_RESEARCH" "$PLANNER_MD" 2>/dev/null && \
   grep -qE "NEEDS_RESEARCH" "$REVIEWER_MD" 2>/dev/null; then
    pass "N3a: all three files contain NEEDS_RESEARCH"
else
    fail "N3a: all three files contain NEEDS_RESEARCH"
fi

# N3b: 'skill: deep-research' in PLANNER_MD (format spec; SKILL.md references planner.md)
if grep -qE "skill:[[:space:]]*deep-research" "$PLANNER_MD" 2>/dev/null; then
    pass "N3b: 'skill: deep-research' appears in PLANNER_MD"
else
    fail "N3b: 'skill: deep-research' must appear in PLANNER_MD"
fi

# N3c: PLANNER_MD contains 'question:' (format field)
if grep -qE "question:" "$PLANNER_MD" 2>/dev/null; then
    pass "N3c: PLANNER_MD contains 'question:'"
else
    fail "N3c: PLANNER_MD must contain 'question:'"
fi

# N3d: PLANNER_MD contains 'reason:' (format field)
if grep -qE "reason:" "$PLANNER_MD" 2>/dev/null; then
    pass "N3d: PLANNER_MD contains 'reason:'"
else
    fail "N3d: PLANNER_MD must contain 'reason:'"
fi

# N3e: both PLANNER_MD and REVIEWER_MD contain '[research:'
if grep -qE '\[research:' "$PLANNER_MD" 2>/dev/null && \
   grep -qE '\[research:' "$REVIEWER_MD" 2>/dev/null; then
    pass "N3e: PLANNER_MD and REVIEWER_MD both contain '[research:'"
else
    fail "N3e: PLANNER_MD and REVIEWER_MD both contain '[research:'"
fi

# N3f: both PLANNER_MD and REVIEWER_MD contain 'Research Findings (from this session)'
if grep -qF "Research Findings (from this session)" "$PLANNER_MD" 2>/dev/null && \
   grep -qF "Research Findings (from this session)" "$REVIEWER_MD" 2>/dev/null; then
    pass "N3f: PLANNER_MD and REVIEWER_MD both contain 'Research Findings (from this session)'"
else
    fail "N3f: PLANNER_MD and REVIEWER_MD both contain 'Research Findings (from this session)'"
fi

echo ""
# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
echo "--- Error ---"

# E1a/E1b: SKILL_MD states missing/empty fields are malformed
assert_contains "$SKILL_MD" "missing.?empty field|empty field" \
    "E1a/E1b: SKILL_MD contains 'missing/empty field' malformed rule"

# E1c: SKILL_MD states skill: != deep-research is malformed
assert_contains "$SKILL_MD" "skill.*deep-research|deep-research.*skill" \
    "E1c: SKILL_MD contains unsupported skill handling (skill: != deep-research)"

# E2: SKILL_MD: malformed retry does not consume research_rounds
assert_contains "$SKILL_MD" "malformed.{0,120}research_rounds|research_rounds.{0,120}malformed" \
    "E2: SKILL_MD contains text indicating malformed retry does not consume research_rounds"

# E3: SKILL_MD: escalation message for budget exhaustion
assert_contains "$SKILL_MD" "(budget|escalat).{0,120}research|research.{0,120}(budget|escalat)" \
    "E3: SKILL_MD contains escalation message for budget exhaustion"

echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
echo "--- Edge ---"

# Ed1a: SKILL_MD contains 'pending reviewer concerns'
assert_contains "$SKILL_MD" "pending reviewer concerns" \
    "Ed1a: SKILL_MD contains 'pending reviewer concerns'"

# Ed1b: SKILL_MD contains 'initial-draft'
assert_contains "$SKILL_MD" "initial-draft" \
    "Ed1b: SKILL_MD contains 'initial-draft'"

# Ed2: SKILL_MD: NEEDS_RESEARCH does not consume revision_rounds
assert_contains "$SKILL_MD" "revision_rounds" \
    "Ed2: SKILL_MD contains text about revision_rounds (NEEDS_RESEARCH does not consume it)"

# Ed3: SKILL_MD: plan_complete is not emitted on escalation
assert_contains "$SKILL_MD" "plan_complete" \
    "Ed3: SKILL_MD contains 'plan_complete' (contract: not emitted on escalation)"

# Ed4: SKILL_MD contains 'first non-whitespace'
assert_contains "$SKILL_MD" "first non-whitespace" \
    "Ed4: SKILL_MD contains 'first non-whitespace'"

echo ""
# ---------------------------------------------------------------------------
# Idempotency cases
# ---------------------------------------------------------------------------
echo "--- Idempotency ---"

# I1: SKILL_MD contains text that counters are not reset
assert_contains "$SKILL_MD" "reset" \
    "I1: SKILL_MD contains text that counters are not reset"

# I2: REVIEWER_MD contains a pattern matching [a-z0-9-] (kebab-case token in brackets)
assert_contains "$REVIEWER_MD" '\[[a-z0-9-]+\]' \
    "I2: REVIEWER_MD contains kebab-case token in brackets (e.g. [research:...])"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
