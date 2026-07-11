#!/bin/bash
# tests/refactor-design-principles.sh
# Tests: agents/detail-reviewer.md, agents/outline-reviewer.md, hooks/workflow-mark.js, skills/make-detail-plan/SKILL.md, skills/survey-code/SKILL.md
# Tags: workflow, outline, planning, detail, survey
#
# Integration tests for the refactor/design-principles branch.
#
# Section A: USER_VERIFIED sentinel — soft warnings + state recording
# Section B: Static checks — rules/core-principles.md,
#            skills/make-detail-plan/SKILL.md, skills/survey-code/SKILL.md

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/refactor-design-principles/helpers.sh
. "$AGENTS_DIR/tests/refactor-design-principles/helpers.sh"
# shellcheck source=tests/refactor-design-principles/section-a.sh
. "$AGENTS_DIR/tests/refactor-design-principles/section-a.sh"
# shellcheck source=tests/refactor-design-principles/section-b.sh
. "$AGENTS_DIR/tests/refactor-design-principles/section-b.sh"

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    # A: USER_VERIFIED sentinel
    test_A1_bare_user_verified_rejected_as_malformed
    test_A2_valid_reason_records_without_warn
    test_A3_short_reason_records_and_warns
    test_A4_no_session_id_not_recorded
    # B: static checks
    test_B1_core_principles_exists
    test_B2_elevate_perspective_header
    test_B3_orthogonality_header
    test_B4_name_reflects_substance_header
    test_B5_orthogonality_md_removed
    test_B6_make_detail_plan_references_core_principles
    test_B7_survey_code_references_core_principles
    test_B8_no_residual_plan_principles_references
    test_B9_ssot_section_header
    test_B14_user_centric_behavior_header
    test_B15_separate_concerns_header
    test_B16_all_cpr_headers_present
    test_B17_no_legacy_numbered_headers
    test_B10_elevate_perspective_per_class_wording
    test_B11_outline_reviewer_references_core_principles
    test_B12_detail_reviewer_references_core_principles
    test_B13_plan_principles_old_path_removed
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_DESIGN_PRINCIPLES_TEST_INNER:-}" ]; then
        _DESIGN_PRINCIPLES_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
