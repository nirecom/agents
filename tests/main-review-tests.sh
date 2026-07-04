#!/usr/bin/env bash
# Tests: skills/review-tests/SKILL.md
# Tags: frontmatter, tests, review, scope:common
# Structural tests for skills/review-tests/SKILL.md
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/review-tests/SKILL.md"

echo "=== review-tests skill structural tests ==="

# --- Normal case 1: SKILL.md exists ---
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi

# --- Normal case 2: frontmatter has required fields ---
for field in name description model effort; do
    if [ -f "$SKILL" ] && grep -qE "^${field}:" "$SKILL" 2>/dev/null; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done

# --- Normal case 3: name field is review-tests ---
if [ -f "$SKILL" ] && grep -qE '^name: review-tests$' "$SKILL" 2>/dev/null; then
    pass "name is 'review-tests'"
else
    fail "name is not 'review-tests'"
fi

# --- Normal case 4: model is sonnet ---
if [ -f "$SKILL" ] && grep -qE '^model: sonnet$' "$SKILL" 2>/dev/null; then
    pass "frontmatter model is 'sonnet'"
else
    fail "frontmatter model is not 'sonnet'"
fi

# --- Normal case 5: effort is low ---
if [ -f "$SKILL" ] && grep -qE '^effort: low$' "$SKILL" 2>/dev/null; then
    pass "frontmatter effort is 'low'"
else
    fail "frontmatter effort is not 'low'"
fi

# --- Normal case 6: has ## Procedure section ---
if [ -f "$SKILL" ] && grep -qE '^## Procedure' "$SKILL" 2>/dev/null; then
    pass "has ## Procedure section"
else
    fail "missing ## Procedure section"
fi

# --- Normal case 7: has ## Rules section ---
if [ -f "$SKILL" ] && grep -qE '^## Rules' "$SKILL" 2>/dev/null; then
    pass "has ## Rules section"
else
    fail "missing ## Rules section"
fi

# --- Normal case 8: step labels RT-1 through RT-4 present ---
for label in RT-1 RT-2 RT-3 RT-4; do
    if [ -f "$SKILL" ] && grep -qF "$label" "$SKILL" 2>/dev/null; then
        pass "step label '$label' present"
    else
        fail "step label '$label' missing"
    fi
done

# --- Normal case 9: drives Codex via run-codex-review-loop.sh ---
if [ -f "$SKILL" ] && grep -qF 'run-codex-review-loop.sh' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references run-codex-review-loop.sh"
else
    fail "SKILL.md does not reference run-codex-review-loop.sh"
fi

# --- Normal case 10: references test-design.md ---
if [ -f "$SKILL" ] && grep -qF 'test-design.md' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references test-design.md"
else
    fail "SKILL.md does not reference test-design.md"
fi

# --- Normal case 11: WORKFLOW_REVIEW_TESTS_COMPLETE sentinel present ---
if [ -f "$SKILL" ] && grep -qF 'WORKFLOW_REVIEW_TESTS_COMPLETE' "$SKILL" 2>/dev/null; then
    pass "WORKFLOW_REVIEW_TESTS_COMPLETE sentinel present"
else
    fail "WORKFLOW_REVIEW_TESTS_COMPLETE sentinel missing"
fi

# --- Normal case 12: WORKFLOW_REVIEW_TESTS_WARNINGS sentinel present ---
if [ -f "$SKILL" ] && grep -qF 'WORKFLOW_REVIEW_TESTS_WARNINGS' "$SKILL" 2>/dev/null; then
    pass "WORKFLOW_REVIEW_TESTS_WARNINGS sentinel present"
else
    fail "WORKFLOW_REVIEW_TESTS_WARNINGS sentinel missing"
fi

# --- Edge case 13: no absolute paths (public repo leak check) ---
if [ -f "$SKILL" ] && grep -qiE '(^|[^a-zA-Z])(c:/|/home/|/Users/)' "$SKILL" 2>/dev/null; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi

# --- Edge case 14: no references to dotfiles-private/ ---
if [ -f "$SKILL" ] && grep -qF 'dotfiles-private/' "$SKILL" 2>/dev/null; then
    fail "SKILL.md references dotfiles-private/ (private repo leak)"
else
    pass "no references to dotfiles-private/ in SKILL.md"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
