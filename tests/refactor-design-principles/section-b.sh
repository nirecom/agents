# section-b.sh — Section B: Static checks
# Tests: rules/core-principles.md
# Tags: core-principles, design, scope:common
# Sourced by tests/refactor-design-principles.sh after helpers.sh.
#
# TL3 gap (what these checks do NOT catch):
# - Static-text assertions against rules/core-principles.md on disk; they say nothing
#   about the prompt a live planner/reviewer/Codex context actually receives.
# - Whether an agent applies CPR-E2C or CPR-ORTH once renamed — only observable in a
#   real `claude -p` session, not in a grep over the rule file.
# - Whether a skill referencing core-principles.md silently stops loading it; such a
#   skill still passes every case here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration (the #1858 sweep
# edits skills/**/*.md, so the classifier raises "Did you run the skill end-to-end?").

# Body of ONE CPR section from rules/core-principles.md: lines after its
# `## CPR-<code>` heading, up to the next `## ` heading. Local to this fragment —
# helpers.sh carries no extractor, and reaching into tests/refactor-1364-cpr-principles.sh
# would couple two independently-runnable suites. The `([ \t]|$)` boundary is mandatory:
# without it `E2C` matches the `CPR-E2E` heading and `UO` matches `CPR-UNV`.
cpr_section_b() {
    awk -v code="$1" '
        $0 ~ "^## CPR-" code "([ \t]|$)" { inside = 1; next }
        inside && /^## / { inside = 0 }
        inside { print }
    ' "$AGENTS_DIR/rules/core-principles.md"
}

test_B1_core_principles_exists() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ -f "$f" ]; then
        pass "B1: rules/core-principles.md exists"
    else
        fail "B1: rules/core-principles.md NOT found"
    fi
}

test_B2_elevate_to_the_class_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qxF "## CPR-E2C Elevate to the Class" "$f"; then
        pass "B2: '## CPR-E2C Elevate to the Class' header present"
    else
        fail "B2: no line in rules/core-principles.md equals '## CPR-E2C Elevate to the Class' exactly (whole line, no trailing text)"
    fi
}

test_B3_orthogonality_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B3: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qxF "## CPR-ORTH Orthogonality" "$f"; then
        pass "B3: '## CPR-ORTH Orthogonality' header present"
    else
        fail "B3: no line in rules/core-principles.md equals '## CPR-ORTH Orthogonality' exactly (whole line, no trailing text)"
    fi
}

test_B4_name_reflects_substance_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B4: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qxF "## CPR-NRS Name Reflects Substance" "$f"; then
        pass "B4: '## CPR-NRS Name Reflects Substance' header present"
    else
        fail "B4: no line in rules/core-principles.md equals '## CPR-NRS Name Reflects Substance' exactly (whole line, no trailing text)"
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
    if grep -qxF "## CPR-SSOT Single Source of Truth" "$f"; then
        pass "B9: '## CPR-SSOT Single Source of Truth' header present"
    else
        fail "B9: no line in rules/core-principles.md equals '## CPR-SSOT Single Source of Truth' exactly (whole line, no trailing text)"
    fi
}

test_B10_elevate_to_the_class_per_class_wording() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B10: rules/core-principles.md not found (prerequisite)"
        return
    fi
    # Scoped to the CPR-E2C section body, not the whole file: a whole-file grep passes
    # even if the wording drifted into some other principle's body, which would prove
    # nothing about CPR-E2C.
    if cpr_section_b E2C | grep -qF "merged, replaced, or restructured"; then
        pass "B10: CPR-E2C section body contains class-level alternative wording"
    else
        fail "B10: 'merged, replaced, or restructured' NOT found inside the CPR-E2C section body"
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

test_B14_user_obsessed_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B14: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qxF "## CPR-UO User-Obsessed" "$f"; then
        pass "B14: '## CPR-UO User-Obsessed' header present"
    else
        fail "B14: no line in rules/core-principles.md equals '## CPR-UO User-Obsessed' exactly (whole line, no trailing text)"
    fi
}

test_B15_separate_concerns_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B15: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qxF "## CPR-SC Separate the Concerns" "$f"; then
        pass "B15: '## CPR-SC Separate the Concerns' header present"
    else
        fail "B15: no line in rules/core-principles.md equals '## CPR-SC Separate the Concerns' exactly (whole line, no trailing text)"
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
        "## CPR-UO User-Obsessed" \
        "## CPR-WPH Why Precedes How" \
        "## CPR-SC Separate the Concerns" \
        "## CPR-SSOT Single Source of Truth" \
        "## CPR-E2C Elevate to the Class" \
        "## CPR-ORTH Orthogonality" \
        "## CPR-E2E End-to-End Integrity" \
        "## CPR-NRS Name Reflects Substance" \
        "## CPR-UNV Universality"; do
        # -x: the heading must be the WHOLE line. A substring match would accept
        # arbitrary trailing text (e.g. "## CPR-UNV Universality First" satisfying
        # the "## CPR-UNV Universality" row), which is exactly the drift #1858 renames away.
        grep -qxF "$h" "$f" || missing="$missing; $h"
    done
    if [ -z "$missing" ]; then
        pass "B16: all 9 CPR headings match their expected line exactly"
    else
        fail "B16: no line matches these headings exactly (whole line, no trailing text):$missing"
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

# B16 now anchors every heading to the whole line (grep -qxF), so it alone rejects
# "## CPR-UNV Universality First". B18 is retained as defense in depth on a WIDER
# scope: it scans the entire file, additionally catching the stale phrase anywhere in
# a principle body, intro paragraph, or cross-reference — none of which any heading
# assertion looks at.
test_B18_no_universality_first() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B18: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "Universality First" "$f"; then
        fail "B18: legacy phrase 'Universality First' still present in rules/core-principles.md"
    else
        pass "B18: 'Universality First' dropped — principle is named 'Universality'"
    fi
}

# The CPR-ORTH body carries an in-file self-reference: before #1858 "CPR-4 specialized [CPR-LEGACY-ID-OK]
# to symmetric pairs and families", after it "CPR-E2C specialized to…". No header
# assertion and no whole-file scan can tell whether that pointer landed in the right
# section — only the section body can.
#
# The literal old ID below is deliberate and is exempted from the repo-wide numeric
# sweep by the line-scoped [CPR-LEGACY-ID-OK] marker — rewriting it to the new code
# would make this case assert the opposite of its purpose. Marker contract (when one
# may be added) is documented at CPR_LEGACY_ID_MARKER in
# tests/refactor-1364-cpr-principles/mapping.sh.
test_B19_orth_references_e2c() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B19: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local body problems=""
    body="$(cpr_section_b ORTH)"
    if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
        fail "B19: CPR-ORTH section body is empty — cannot verify its cross-reference"
        return
    fi
    printf '%s\n' "$body" | grep -qF "CPR-E2C" \
        || problems="$problems; body does not reference CPR-E2C"
    # Targeted, not a second global numeric sweep — G1 in
    # tests/refactor-1364-cpr-principles.sh owns residual CPR-<N> repo-wide. This
    # says only: the stale pointer must be gone from THIS section.
    if printf '%s\n' "$body" | grep -qE "CPR-4([^0-9]|$)"; then  # [CPR-LEGACY-ID-OK]
        problems="$problems; stale 'CPR-4' pointer still inside the CPR-ORTH body"  # [CPR-LEGACY-ID-OK]
    fi
    if [ -z "$problems" ]; then
        pass "B19: CPR-ORTH body cross-references CPR-E2C with no stale CPR-4 pointer"  # [CPR-LEGACY-ID-OK]
    else
        fail "B19: CPR-ORTH cross-reference not remapped$problems"
    fi
}
