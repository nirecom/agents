#!/usr/bin/env bash
# Contract tests for clarify-intent skill (Stage 1: interactive user interview)
# Target files (expected to FAIL until implementation is complete):
#   $HOME/.claude/skills/clarify-intent/SKILL.md
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

SKILL_MD="$HOME/.claude/skills/clarify-intent/SKILL.md"

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

echo "=== clarify-intent contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases
# ---------------------------------------------------------------------------
echo "--- Normal ---"

# N1: frontmatter contains name: clarify-intent
assert_contains "$SKILL_MD" "name:[[:space:]]*clarify-intent" \
    "N1: frontmatter contains 'name: clarify-intent'"

# N2: interactive or AskUserQuestion appears (interactive context requirement)
assert_contains "$SKILL_MD" "interactive|AskUserQuestion" \
    "N2: 'interactive' or 'AskUserQuestion' appears (interactive context requirement)"

# N3: output path ~/.claude/plans/ or $HOME/.claude/plans/ mentioned
assert_contains "$SKILL_MD" '~/.claude/plans/|\$HOME/.claude/plans/' \
    "N3: output path ~/.claude/plans/ or \$HOME/.claude/plans/ mentioned"

# N4: <session-id>-intent.md output filename mentioned
assert_contains "$SKILL_MD" "session.id.*intent\.md|intent\.md" \
    "N4: session-id intent.md output filename mentioned"

# N5: recommended answer instruction mentioned
assert_contains "$SKILL_MD" '推奨|recommended|\(推奨\)' \
    "N5: recommended answer instruction mentioned (推奨 or recommended)"

# N6: 5-round cap mentioned
assert_contains "$SKILL_MD" "5.*round|round.*5|上限.*5|5.*上限" \
    "N6: 5-round cap mentioned"

# N7: plan-skip.md referenced
assert_contains "$SKILL_MD" "plan-skip\.md" \
    "N7: plan-skip.md referenced"

# N8: grill-me / Matt Pocock attribution mentioned
assert_contains "$SKILL_MD" "grill.me|Matt Pocock|mattpocock" \
    "N8: grill-me / Matt Pocock attribution mentioned"

# N9: intent.md mentioned in output context
assert_contains "$SKILL_MD" "intent\.md" \
    "N9: intent.md mentioned in output context"

echo ""
# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
echo "--- Error ---"

# E1: hard-fail on non-interactive
assert_contains "$SKILL_MD" "hard.fail|hard_fail|診断|diagnostic" \
    "E1: hard-fail on non-interactive mentioned"

# E2: 'do not silently proceed' or '暗黙' prohibition mentioned
assert_contains "$SKILL_MD" "[Dd]o not silently proceed|暗黙" \
    "E2: 'do not silently proceed' or '暗黙' prohibition mentioned"

echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
echo "--- Edge ---"

# Ed1: session-id appears in output path context (parameterized output)
assert_contains "$SKILL_MD" "session.id|session_id" \
    "Ed1: session-id appears in output path context (parameterized output)"

# Ed2: round limit is specifically 5 — check both "5" and "round" present in file
if [ ! -f "$SKILL_MD" ]; then
    fail "Ed2: round limit is specifically 5 (file not found: $SKILL_MD)"
elif grep -qE "5" "$SKILL_MD" && grep -qE "round" "$SKILL_MD"; then
    pass "Ed2: round limit is specifically 5 (both '5' and 'round' present in file)"
else
    fail "Ed2: round limit is specifically 5 (need both '5' and 'round' in file)"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
