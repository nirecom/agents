#!/usr/bin/env bash
# Structural tests for claude-global/skills/save-research/SKILL.md
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$DOTFILES_DIR/claude-global/skills/save-research/SKILL.md"

echo "=== save-research skill structural tests ==="

# Normal: SKILL.md exists
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi

# Normal: has required frontmatter fields
for field in name description model effort; do
    if grep -qE "^${field}:" "$SKILL"; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done

# Normal: name field is save-research
if grep -qE '^name: save-research$' "$SKILL"; then
    pass "name is 'save-research'"
else
    fail "name is not 'save-research'"
fi

# Normal: has Procedure and Rules sections
for section in Procedure Rules; do
    if grep -qE "^## ${section}" "$SKILL"; then
        pass "has ## $section section"
    else
        fail "missing ## $section section"
    fi
done

# Normal: uses relative path (no absolute paths to ai-specs)
if grep -qF '../ai-specs/' "$SKILL"; then
    pass "uses relative path ../ai-specs/"
else
    fail "does not use relative path ../ai-specs/"
fi

# Edge: no absolute paths leaked (c:/ or /home/ etc.)
if grep -qiE '(^|[^.])[a-z]:[/\\]|/home/' "$SKILL"; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi

# Normal: references research-results directory
if grep -qF 'research-results/' "$SKILL"; then
    pass "references research-results/ directory"
else
    fail "does not reference research-results/ directory"
fi

# Normal: requires source URLs
if grep -qi 'source.*URL' "$SKILL"; then
    pass "mentions source URLs requirement"
else
    fail "does not mention source URLs requirement"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
