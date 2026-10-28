# Group A: test-design.md governance content (Cases 1-3)
# Sourced by tests/skills/feature-test-cleanup-944.sh

if [[ -f "$TEST_DESIGN" ]]; then
    if grep -qE 'scope:[[:space:]]*issue-specific|scope:issue-specific' "$TEST_DESIGN"; then
        pass "Case 1: test-design.md defines scope:issue-specific"
    else
        fail "Case 1: test-design.md missing scope:issue-specific definition"
    fi

    if grep -qE 'scope:[[:space:]]*common|scope:common' "$TEST_DESIGN"; then
        pass "Case 2: test-design.md defines scope:common"
    else
        fail "Case 2: test-design.md missing scope:common definition"
    fi

    if grep -qE '^## Size Limits' "$TEST_DESIGN" \
       && grep -qE 'kind `code` of the generated Size limits table in `rules/coding/file-split.md`' "$TEST_DESIGN"; then
        pass "Case 3: test-design.md size limits reference the SSOT table (kind code)"
    else
        fail "Case 3: test-design.md missing size limits section"
    fi
else
    skip "Cases 1-3: test-design.md does not exist yet"
fi
