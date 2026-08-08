#!/bin/bash
# structural-tests.sh: SKILL.md + guard structural assertions (S-series)
# Tests: skills/session-close/SKILL.md, bin/render-final-report.js, hooks/stop-final-report-guard.js
#
# Sourced helpers: feature-1463-session-close-scriptify/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_S1_skill_no_node_e() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S1_skill_no_node_e (skills/session-close/SKILL.md missing)"
        return
    fi
    local n; n="$(grep -cF "node -e" "$SKILL_MD" 2>/dev/null || true)"
    if [ "$n" = "0" ]; then
        pass "S1_skill_no_node_e: SKILL.md contains 0 'node -e' occurrences"
    else
        fail "S1_skill_no_node_e: expected 0 'node -e', found $n"
    fi
}

test_S2_skill_under_200_lines() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S2_skill_under_200_lines (skills/session-close/SKILL.md missing)"
        return
    fi
    local n; n="$(wc -l < "$SKILL_MD" | tr -d ' ')"
    if [ "$n" -lt 200 ]; then
        pass "S2_skill_under_200_lines: SKILL.md is $n lines (<200)"
    else
        fail "S2_skill_under_200_lines: SKILL.md is $n lines (expected <200)"
    fi
}

test_S3_skill_refs_render() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S3_skill_refs_render (skills/session-close/SKILL.md missing)"
        return
    fi
    if grep -qF "bin/render-final-report.js" "$SKILL_MD"; then
        pass "S3_skill_refs_render: SKILL.md references bin/render-final-report.js"
    else
        fail "S3_skill_refs_render: SKILL.md does not reference bin/render-final-report.js"
    fi
}

test_S4_skill_refs_detect() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S4_skill_refs_detect (skills/session-close/SKILL.md missing)"
        return
    fi
    if grep -qF "bin/session-close-detect-wf-meta.js" "$SKILL_MD"; then
        pass "S4_skill_refs_detect: SKILL.md references bin/session-close-detect-wf-meta.js"
    else
        fail "S4_skill_refs_detect: SKILL.md does not reference bin/session-close-detect-wf-meta.js"
    fi
}

test_S5_skill_refs_sc7() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S5_skill_refs_sc7 (skills/session-close/SKILL.md missing)"
        return
    fi
    if grep -qF "bin/session-close-render-sc7.js" "$SKILL_MD"; then
        pass "S5_skill_refs_sc7: SKILL.md references bin/session-close-render-sc7.js"
    else
        fail "S5_skill_refs_sc7: SKILL.md does not reference bin/session-close-render-sc7.js"
    fi
}

test_S6_render_requires_schema() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "S6_render_requires_schema (bin/render-final-report.js missing)"
        return
    fi
    if grep -qE "require\(.*final-report-schema" "$RENDER_JS"; then
        pass "S6_render_requires_schema: render-final-report.js requires hooks/lib/final-report-schema"
    else
        fail "S6_render_requires_schema: render-final-report.js does not require final-report-schema"
    fi
}

# S7: SSOT moved to schema — the guard no longer defines its own
# buildPostMergeReminder function locally.
test_S7_guard_no_local_postmerge() {
    if [ ! -f "$GUARD_JS" ]; then
        skip "S7_guard_no_local_postmerge (hooks/stop-final-report-guard.js missing)"
        return
    fi
    if grep -qE "function[[:space:]]+buildPostMergeReminder" "$GUARD_JS"; then
        fail "S7_guard_no_local_postmerge: guard still defines local 'function buildPostMergeReminder' (SSOT not moved)"
    else
        pass "S7_guard_no_local_postmerge: guard has no local buildPostMergeReminder (SSOT in schema)"
    fi
}

# ============ Run all ============

test_S1_skill_no_node_e
test_S2_skill_under_200_lines
test_S3_skill_refs_render
test_S4_skill_refs_detect
test_S5_skill_refs_sc7
test_S6_render_requires_schema
test_S7_guard_no_local_postmerge

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
