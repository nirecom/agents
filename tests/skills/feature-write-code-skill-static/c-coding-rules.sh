#!/bin/bash
# Tests: rules/coding/python.md
# Tags: skill, config, static, scope:common
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): the language rule files keep their paths: frontmatter.

# ---------------------------------------------------------------------------
# k. rules/coding/python.md retains paths: frontmatter
# ---------------------------------------------------------------------------
echo "=== k. rules/coding/python.md has paths: frontmatter ==="
if require_file "$PYTHON_RULES"; then
    if head -10 "$PYTHON_RULES" | grep -F "paths:" >/dev/null 2>&1; then
        pass "rules/coding/python.md retains 'paths:' frontmatter"
    else
        fail "rules/coding/python.md missing 'paths:' in first 10 lines"
    fi
fi

# ---------------------------------------------------------------------------
# l. rules/coding/nodejs.md retains paths: frontmatter
# ---------------------------------------------------------------------------
echo "=== l. rules/coding/nodejs.md has paths: frontmatter ==="
if require_file "$NODEJS_RULES"; then
    if head -10 "$NODEJS_RULES" | grep -F "paths:" >/dev/null 2>&1; then
        pass "rules/coding/nodejs.md retains 'paths:' frontmatter"
    else
        fail "rules/coding/nodejs.md missing 'paths:' in first 10 lines"
    fi
fi
