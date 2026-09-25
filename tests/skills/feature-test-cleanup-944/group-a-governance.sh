# Group A: test-design.md governance content (Cases 1-3)
# Sourced by tests/feature-test-cleanup-944.sh

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

    if grep -qE '300' "$TEST_DESIGN" && grep -qE '500' "$TEST_DESIGN" \
       && grep -qiE 'WARN|warn' "$TEST_DESIGN" && grep -qiE 'HARD|hard' "$TEST_DESIGN"; then
        pass "Case 3: test-design.md contains size limits (300 WARN / 500 HARD)"
    else
        fail "Case 3: test-design.md missing size limits section"
    fi
else
    skip "Cases 1-3: test-design.md does not exist yet"
fi
