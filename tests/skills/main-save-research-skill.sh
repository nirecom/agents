#!/usr/bin/env bash
# Tests: skills/save-research/SKILL.md
# Tags: frontmatter, tests, research, skill, bin, scope:common
# Structural tests for skills/save-research/SKILL.md
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/save-research/SKILL.md"

echo "=== save-research skill structural tests ==="

# Normal: SKILL.md exists
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi

# Normal: has required frontmatter fields
for field in name description model; do
    if [ -f "$SKILL" ] && grep -qE "^${field}:" "$SKILL" 2>/dev/null; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done

# Normal: effort is ABSENT (effort: line removed in #2100)
# Requires write_code to delete 'effort:' from frontmatter — FAILS until then.
if [ -f "$SKILL" ] && grep -qE '^effort:' "$SKILL" 2>/dev/null; then
    fail "frontmatter 'effort:' must be absent (was not yet removed)"
else
    pass "frontmatter 'effort:' is absent"
fi

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

# Normal: uses relative path (no absolute paths to my-specs-repo)
if grep -qF '../my-specs-repo/' "$SKILL"; then
    pass "uses relative path ../my-specs-repo/"
else
    fail "does not use relative path ../my-specs-repo/"
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
