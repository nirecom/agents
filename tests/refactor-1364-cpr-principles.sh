#!/bin/bash
# tests/refactor-1364-cpr-principles.sh
# Tests: rules/core-principles.md, CLAUDE.md, agents/supervisor.md, skills/survey-history/SKILL.md, agents/detail-planner.md, agents/detail-reviewer.md, agents/outline-reviewer.md, skills/survey-code/SKILL.md
# Tags: core-principles, refactor, scope:issue-specific
#
# Structural tests for issue #1364 — renumber core-principles.md sections to the
# CPR-N scheme, add CPR-3 "切り分けて考える" (separation-of-concerns) principle,
# and purge legacy §N cross-references from downstream prompt files.
#
# fail-before-fix: authored before the source edits land. Many cases FAIL until
# rules/core-principles.md is renumbered and downstream files are updated.
#
# L3 gap: these are static-text assertions only. Whether the renumbered principles
# and CPR-3 are actually loaded into a live planner/reviewer/Codex context — and
# whether Claude Code honors them at runtime — can only be verified in an L3
# session with a real `claude -p` invocation. Not covered here.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

CORE="$AGENTS_DIR/rules/core-principles.md"

# ============================================================================
# N: positive cases — expected structure after the refactor
# ============================================================================

test_N1_all_cpr_headers_present() {
    if [ ! -f "$CORE" ]; then
        fail "N1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local missing=""
    local n
    for n in 1 2 3 4 5 6 7 8; do
        if ! grep -qE "^## CPR-${n}\b" "$CORE"; then
            missing="$missing CPR-$n"
        fi
    done
    if [ -z "$missing" ]; then
        pass "N1: all CPR-1..CPR-8 headers present"
    else
        fail "N1: missing CPR headers:$missing"
    fi
}

test_N2_cpr3_new_principle() {
    if [ ! -f "$CORE" ]; then
        fail "N2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "^## CPR-3\b" "$CORE"; then
        pass "N2: '## CPR-3' new principle header present"
    else
        fail "N2: '## CPR-3' header NOT found in rules/core-principles.md"
    fi
}


test_N4_supervisor_no_legacy_section_ref() {
    local f="$AGENTS_DIR/agents/supervisor.md"
    if [ ! -f "$f" ]; then
        fail "N4: agents/supervisor.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N4: legacy §N reference still present in agents/supervisor.md"
    else
        pass "N4: no legacy §N reference in agents/supervisor.md"
    fi
}

test_N5_survey_history_no_legacy_section_ref() {
    local f="$AGENTS_DIR/skills/survey-history/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "N5: skills/survey-history/SKILL.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N5: legacy §N reference still present in skills/survey-history/SKILL.md"
    else
        pass "N5: no legacy §N reference in skills/survey-history/SKILL.md"
    fi
}

test_N6_detail_planner_no_legacy_section_ref() {
    local f="$AGENTS_DIR/agents/detail-planner.md"
    if [ ! -f "$f" ]; then
        fail "N6: agents/detail-planner.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N6: legacy §N reference still present in agents/detail-planner.md"
    else
        pass "N6: no legacy §N reference in agents/detail-planner.md"
    fi
}

test_N7_detail_reviewer_no_legacy_section_ref() {
    local f="$AGENTS_DIR/agents/detail-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "N7: agents/detail-reviewer.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N7: legacy §N reference still present in agents/detail-reviewer.md"
    else
        pass "N7: no legacy §N reference in agents/detail-reviewer.md"
    fi
}

test_N8_outline_reviewer_no_legacy_section_ref() {
    local f="$AGENTS_DIR/agents/outline-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "N8: agents/outline-reviewer.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N8: legacy §N reference still present in agents/outline-reviewer.md"
    else
        pass "N8: no legacy §N reference in agents/outline-reviewer.md"
    fi
}

test_N9_survey_code_no_legacy_section_ref() {
    local f="$AGENTS_DIR/skills/survey-code/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "N9: skills/survey-code/SKILL.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$f"; then
        fail "N9: legacy §N reference still present in skills/survey-code/SKILL.md"
    else
        pass "N9: no legacy §N reference in skills/survey-code/SKILL.md"
    fi
}

# ============================================================================
# L: negative cases — legacy forms must be gone from core-principles.md
# ============================================================================

test_L1_no_legacy_section_ref_in_core() {
    if [ ! -f "$CORE" ]; then
        fail "L1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$CORE"; then
        fail "L1: legacy §N cross-reference still present in rules/core-principles.md"
    else
        pass "L1: no legacy §N cross-reference in rules/core-principles.md"
    fi
}

test_L2_no_old_numbered_header() {
    if [ ! -f "$CORE" ]; then
        fail "L2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "^## [0-9]+\." "$CORE"; then
        fail "L2: legacy '## N.' numbered header still present in rules/core-principles.md"
    else
        pass "L2: no legacy '## N.' numbered header in rules/core-principles.md"
    fi
}

# ============================================================================
# S: structural case — exact CPR header count
# ============================================================================

test_S1_exactly_8_cpr_headers() {
    if [ ! -f "$CORE" ]; then
        fail "S1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local count
    count="$(grep -c "^## CPR-" "$CORE")"
    if [ "$count" -eq 8 ]; then
        pass "S1: exactly 8 '## CPR-' headers"
    else
        fail "S1: expected 8 '## CPR-' headers, found $count"
    fi
}

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    test_N1_all_cpr_headers_present
    test_N2_cpr3_new_principle
    test_N4_supervisor_no_legacy_section_ref
    test_N5_survey_history_no_legacy_section_ref
    test_N6_detail_planner_no_legacy_section_ref
    test_N7_detail_reviewer_no_legacy_section_ref
    test_N8_outline_reviewer_no_legacy_section_ref
    test_N9_survey_code_no_legacy_section_ref
    test_L1_no_legacy_section_ref_in_core
    test_L2_no_old_numbered_header
    test_S1_exactly_8_cpr_headers
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_CPR_TEST_INNER:-}" ]; then
        _CPR_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
