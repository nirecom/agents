#!/usr/bin/env bash
# Tests: skills/review-plan-security/SKILL.md, skills/review-code-security/SKILL.md
# Tags: frontmatter, tests, security, plan, review, scope:common
# Structural tests for skills/review-plan-security/SKILL.md
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/review-plan-security/SKILL.md"
CODE_SKILL="$ROOT/skills/review-code-security/SKILL.md"

echo "=== review-plan-security skill structural tests ==="

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

# --- Normal case 3: name field is review-plan-security ---
if [ -f "$SKILL" ] && grep -qE '^name: review-plan-security$' "$SKILL" 2>/dev/null; then
    pass "name is 'review-plan-security'"
else
    fail "name is not 'review-plan-security'"
fi

# --- Normal case 4: model is opus ---
if [ -f "$SKILL" ] && grep -qE '^model: opus$' "$SKILL" 2>/dev/null; then
    pass "frontmatter model is 'opus'"
else
    fail "frontmatter model is not 'opus'"
fi

# --- Normal case 5: effort is medium ---
if [ -f "$SKILL" ] && grep -qE '^effort: medium$' "$SKILL" 2>/dev/null; then
    pass "frontmatter effort is 'medium'"
else
    fail "frontmatter effort is not 'medium'"
fi

# --- Normal case 6: has ## Procedure section ---
if [ -f "$SKILL" ] && grep -qE '^## Procedure' "$SKILL" 2>/dev/null; then
    pass "has ## Procedure section"
else
    fail "missing ## Procedure section"
fi

# --- Normal case 7: step labels RPS-1 through RPS-4 present ---
for label in RPS-1 RPS-2 RPS-3 RPS-4; do
    if [ -f "$SKILL" ] && grep -qF "$label" "$SKILL" 2>/dev/null; then
        pass "step label '$label' present"
    else
        fail "step label '$label' missing"
    fi
done

# --- Normal case 8: drives Codex via run-codex-review-loop.sh ---
if [ -f "$SKILL" ] && grep -qF 'run-codex-review-loop.sh' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references run-codex-review-loop.sh"
else
    fail "SKILL.md does not reference run-codex-review-loop.sh"
fi

# --- Normal case 9: cross-references /review-code-security ---
if [ -f "$SKILL" ] && grep -qF '/review-code-security' "$SKILL" 2>/dev/null; then
    pass "cross-references /review-code-security"
else
    fail "does not cross-reference /review-code-security"
fi

# --- Normal case 10: names plan-security-reviewer fallback agent ---
if [ -f "$SKILL" ] && grep -qF 'plan-security-reviewer' "$SKILL" 2>/dev/null; then
    pass "names 'plan-security-reviewer' fallback agent"
else
    fail "does not name 'plan-security-reviewer' fallback agent"
fi

# --- Edge case 11: no absolute paths (public repo leak check) ---
if [ -f "$SKILL" ] && grep -qiE '(^|[^a-zA-Z])(c:/|/home/|/Users/)' "$SKILL" 2>/dev/null; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi

# --- Edge case 12: no references to my-private-repo/ ---
if [ -f "$SKILL" ] && grep -qF 'my-private-repo/' "$SKILL" 2>/dev/null; then
    fail "SKILL.md references my-private-repo/ (private repo leak)"
else
    pass "no references to my-private-repo/ in SKILL.md"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
