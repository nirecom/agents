# section-b.sh — Section B: Static checks
# Tests: rules/core-principles.md
# Tags: core-principles, design, scope:common
# Sourced by tests/agents/refactor-design-principles.sh after helpers.sh.
#
# The format of rules/core-principles.md itself is owned by tests/bin/core-principles-format.sh;
# these cases only check that the file exists and that its consumers reference it.
# TL3 gap: a grep over a consumer file says nothing about whether a live planner/reviewer/Codex
# context actually loads core-principles.md. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

test_B1_core_principles_exists() {
    local f="$SCRIPT_CHECKOUT_ROOT/rules/core-principles.md"
    if [ -f "$f" ]; then
        pass "B1: rules/core-principles.md exists"
    else
        fail "B1: rules/core-principles.md NOT found"
    fi
}

test_B6_make_detail_plan_references_core_principles() {
    local f="$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "B6: skills/make-detail-plan/SKILL.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B6: skills/make-detail-plan/SKILL.md references rules/core-principles.md"
    else
        fail "B6: skills/make-detail-plan/SKILL.md does NOT reference rules/core-principles.md"
    fi
}

test_B7_survey_code_references_core_principles() {
    local f="$SCRIPT_CHECKOUT_ROOT/skills/survey-code/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "B7: skills/survey-code/SKILL.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B7: skills/survey-code/SKILL.md references rules/core-principles.md"
    else
        fail "B7: skills/survey-code/SKILL.md does NOT reference rules/core-principles.md"
    fi
}

test_B11_outline_reviewer_references_core_principles() {
    local f="$SCRIPT_CHECKOUT_ROOT/agents/outline-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "B11: agents/outline-reviewer.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B11: agents/outline-reviewer.md references rules/core-principles.md"
    else
        fail "B11: agents/outline-reviewer.md does NOT reference rules/core-principles.md"
    fi
}

test_B12_detail_reviewer_references_core_principles() {
    local f="$SCRIPT_CHECKOUT_ROOT/agents/detail-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "B12: agents/detail-reviewer.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B12: agents/detail-reviewer.md references rules/core-principles.md"
    else
        fail "B12: agents/detail-reviewer.md does NOT reference rules/core-principles.md"
    fi
}
