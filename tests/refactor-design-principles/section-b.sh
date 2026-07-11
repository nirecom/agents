# section-b.sh — Section B: Static checks
# Sourced by tests/refactor-design-principles.sh after helpers.sh.

test_B1_core_principles_exists() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ -f "$f" ]; then
        pass "B1: rules/core-principles.md exists"
    else
        fail "B1: rules/core-principles.md NOT found"
    fi
}

test_B2_elevate_perspective_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-4 Elevate Perspective" "$f"; then
        pass "B2: '## CPR-4 Elevate Perspective' header present"
    else
        fail "B2: '## CPR-4 Elevate Perspective' header NOT found in rules/core-principles.md"
    fi
}

test_B3_orthogonality_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B3: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-5 Orthogonality" "$f"; then
        pass "B3: '## CPR-5 Orthogonality' header present"
    else
        fail "B3: '## CPR-5 Orthogonality' header NOT found in rules/core-principles.md"
    fi
}

test_B4_name_reflects_substance_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B4: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-7 Name Reflects Substance" "$f"; then
        pass "B4: '## CPR-7 Name Reflects Substance' header present"
    else
        fail "B4: '## CPR-7 Name Reflects Substance' header NOT found in rules/core-principles.md"
    fi
}

test_B5_orthogonality_md_removed() {
    local f="$AGENTS_DIR/rules/orthogonality.md"
    if [ ! -f "$f" ]; then
        pass "B5: rules/orthogonality.md does not exist (correctly removed)"
    else
        fail "B5: rules/orthogonality.md still exists (should have been removed)"
    fi
}

test_B6_make_detail_plan_references_core_principles() {
    local f="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
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
    local f="$AGENTS_DIR/skills/survey-code/SKILL.md"
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

test_B8_no_residual_plan_principles_references() {
    local hits
    hits=$(cd "$AGENTS_DIR" && git ls-files -z \
           | xargs -0 grep -l 'plan-principles' 2>/dev/null \
           | grep -v '^docs/history' \
           | grep -v '^tests/' || true)
    if [ -z "$hits" ]; then
        pass "B8: no residual 'plan-principles' references in tracked canonical files"
    else
        fail "B8: residual 'plan-principles' references found in: $hits"
    fi
}

test_B9_ssot_section_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B9: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-2 Single Source of Truth" "$f"; then
        pass "B9: '## CPR-2 Single Source of Truth' header present"
    else
        fail "B9: '## CPR-2 Single Source of Truth' header NOT found"
    fi
}

test_B10_elevate_perspective_per_class_wording() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B10: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "merged, replaced, or restructured" "$f"; then
        pass "B10: CPR-4 contains class-level alternative wording"
    else
        fail "B10: CPR-4 does NOT contain class-level alternative wording"
    fi
}

test_B11_outline_reviewer_references_core_principles() {
    local f="$AGENTS_DIR/agents/outline-reviewer.md"
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
    local f="$AGENTS_DIR/agents/detail-reviewer.md"
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

test_B13_plan_principles_old_path_removed() {
    local f="$AGENTS_DIR/rules/plan-principles.md"
    if [ ! -f "$f" ]; then
        pass "B13: rules/plan-principles.md does not exist (correctly renamed)"
    else
        fail "B13: rules/plan-principles.md still exists (should have been renamed)"
    fi
}

test_B14_user_centric_behavior_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B14: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-1 User-Centric Behavior" "$f"; then
        pass "B14: '## CPR-1 User-Centric Behavior' header present"
    else
        fail "B14: '## CPR-1 User-Centric Behavior' header NOT found in rules/core-principles.md"
    fi
}

test_B15_separate_concerns_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B15: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## CPR-3 Separate the Concerns" "$f"; then
        pass "B15: '## CPR-3 Separate the Concerns' header present"
    else
        fail "B15: '## CPR-3 Separate the Concerns' header NOT found"
    fi
}

test_B16_all_cpr_headers_present() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B16: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local missing=""
    local h
    for h in \
        "## CPR-1 User-Centric Behavior" \
        "## CPR-2 Single Source of Truth" \
        "## CPR-3 Separate the Concerns" \
        "## CPR-4 Elevate Perspective" \
        "## CPR-5 Orthogonality" \
        "## CPR-6 End-to-End Integrity" \
        "## CPR-7 Name Reflects Substance" \
        "## CPR-8 Universality First"; do
        grep -qF "$h" "$f" || missing="$missing; $h"
    done
    if [ -z "$missing" ]; then
        pass "B16: all 8 CPR headers present"
    else
        fail "B16: missing CPR headers:$missing"
    fi
}

test_B17_no_legacy_numbered_headers() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B17: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local ok=1
    if grep -nE '^## [1-9]\. ' "$f" >/dev/null 2>&1; then
        ok=0; echo "  found legacy numbered header(s)"
    fi
    if grep -nE '§[1-9]' "$f" >/dev/null 2>&1; then
        ok=0; echo "  found legacy §N reference(s)"
    fi
    if [ $ok -eq 1 ]; then
        pass "B17: no legacy numbered headers or §N references"
    else
        fail "B17: legacy numbered headers or §N references present"
    fi
}
