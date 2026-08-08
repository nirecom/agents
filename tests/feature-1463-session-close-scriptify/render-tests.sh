#!/bin/bash
# render-tests.sh: bin/render-final-report.js existence + rendering behavior
# Tests: bin/render-final-report.js, hooks/lib/final-report-schema.js
# Tags: scope:issue-specific
#
# Sourced helpers: feature-1463-session-close-scriptify/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ============ T1-T3: bin scripts exist ============

test_T1_render_exists() {
    if [ -f "$RENDER_JS" ]; then
        pass "T1_render_exists: bin/render-final-report.js present"
    else
        fail "T1_render_exists: bin/render-final-report.js missing (pending write-code)"
    fi
}

test_T2_detect_exists() {
    if [ -f "$DETECT_JS" ]; then
        pass "T2_detect_exists: bin/session-close-detect-wf-meta.js present"
    else
        fail "T2_detect_exists: bin/session-close-detect-wf-meta.js missing (pending write-code)"
    fi
}

test_T3_sc7_exists() {
    if [ -f "$SC7_JS" ]; then
        pass "T3_sc7_exists: bin/session-close-render-sc7.js present"
    else
        fail "T3_sc7_exists: bin/session-close-render-sc7.js missing (pending write-code)"
    fi
}

# ============ T4-T9: render-final-report.js behavior ============

# T4: valid fixture -> exit 0, output contains the Final Report header and all
# 13 canonical section headings from getSectionHeadings().
test_T4_render_all_headings() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T4_render_all_headings (bin/render-final-report.js missing)"
        return
    fi
    local out code
    out="$(FRE_ENV_JSON="" FRE_OUTCOME_JSON="" FRE_INTENT_MD="" FRE_SUPERVISOR_STATE="" render_report "$SID" 2>/dev/null)"
    code=$?
    if [ "$code" != "0" ]; then
        fail "T4_render_all_headings: expected exit 0, got $code"
        return
    fi
    # Collect the canonical headings from the schema and require each in stdout.
    local headings missing=""
    headings="$(run_with_timeout 120 node -e "
        const s=require('${AGENTS_DIR_NODE}/hooks/lib/final-report-schema');
        process.stdout.write(s.getSectionHeadings('${SID}').join('\n'));
    " 2>/dev/null)"
    if [ -z "$headings" ]; then
        fail "T4_render_all_headings: could not load schema headings"
        return
    fi
    local h
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        if ! printf '%s' "$out" | grep -qF "$h"; then
            missing="${missing}${h}
"
        fi
    done <<< "$headings"
    # The header line "## Final Report — <sid>" is one of the 13; verify explicitly.
    if ! printf '%s' "$out" | grep -qF "## Final Report"; then
        missing="${missing}## Final Report
"
    fi
    if [ -z "$missing" ]; then
        pass "T4_render_all_headings: all 13 section headings present + '## Final Report'"
    else
        fail "T4_render_all_headings: missing headings:
$missing"
    fi
}

# T5: no unresolved <TOKEN> matching the guard's tokenRegex /<[A-Z][A-Z0-9_]+>/.
test_T5_no_unresolved_tokens() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T5_no_unresolved_tokens (bin/render-final-report.js missing)"
        return
    fi
    local out code toks
    out="$(render_report "$SID" 2>/dev/null)"
    code=$?
    if [ "$code" != "0" ]; then
        fail "T5_no_unresolved_tokens: render exited $code (expected 0)"
        return
    fi
    toks="$(printf '%s' "$out" | grep -oE '<[A-Z][A-Z0-9_]+>' || true)"
    if [ -z "$toks" ]; then
        pass "T5_no_unresolved_tokens: output has no <TOKEN> placeholders"
    else
        fail "T5_no_unresolved_tokens: unresolved tokens present:
$toks"
    fi
}

# T6: known fixture values appear (placeholder substitution actually happened).
test_T6_substitution_happened() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T6_substitution_happened (bin/render-final-report.js missing)"
        return
    fi
    local out
    out="$(render_report "$SID" 2>/dev/null)"
    if printf '%s' "$out" | grep -qF "$FIXTURE_PR_TITLE" \
       && printf '%s' "$out" | grep -qF "$FIXTURE_BRANCH"; then
        pass "T6_substitution_happened: fixture PR title + branch appear in output"
    else
        fail "T6_substitution_happened: fixture values not substituted into output"
    fi
}

# T7: missing env JSON -> exit 1.
test_T7_missing_env_exit1() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T7_missing_env_exit1 (bin/render-final-report.js missing)"
        return
    fi
    local code
    FRE_ENV_JSON="${TMPDIR_BASE}/does-not-exist-env.json" render_report "$SID" >/dev/null 2>&1
    code=$?
    if [ "$code" = "1" ]; then
        pass "T7_missing_env_exit1: missing env JSON exits 1"
    else
        fail "T7_missing_env_exit1: expected exit 1, got $code"
    fi
}

# T8: invalid session-id -> exit 1 (guard's id regex is ^[A-Za-z0-9_-]+$).
test_T8_invalid_sid_exit1() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T8_invalid_sid_exit1 (bin/render-final-report.js missing)"
        return
    fi
    local code
    render_report 'bad id/with spaces' >/dev/null 2>&1
    code=$?
    if [ "$code" = "1" ]; then
        pass "T8_invalid_sid_exit1: invalid session-id exits 1"
    else
        fail "T8_invalid_sid_exit1: expected exit 1, got $code"
    fi
}

# T9: missing optional supervisor-state -> exit 0, no unresolved tokens.
test_T9_missing_supervisor_ok() {
    if [ ! -f "$RENDER_JS" ]; then
        skip "T9_missing_supervisor_ok (bin/render-final-report.js missing)"
        return
    fi
    local out code toks
    out="$(FRE_SUPERVISOR_STATE="${TMPDIR_BASE}/absent-supervisor-state.json" render_report "$SID" 2>/dev/null)"
    code=$?
    if [ "$code" != "0" ]; then
        fail "T9_missing_supervisor_ok: expected exit 0 with absent supervisor-state, got $code"
        return
    fi
    toks="$(printf '%s' "$out" | grep -oE '<[A-Z][A-Z0-9_]+>' || true)"
    if [ -z "$toks" ]; then
        pass "T9_missing_supervisor_ok: exit 0 and no unresolved tokens when supervisor-state absent"
    else
        fail "T9_missing_supervisor_ok: unresolved tokens with absent supervisor-state:
$toks"
    fi
}

test_T7b_T7c_missing_required_files() {
    if [ ! -f "$RENDER_JS" ]; then skip "T7b+T7c (bin/render-final-report.js missing)"; return; fi
    FRE_OUTCOME_JSON="$(node_path "${TMPDIR_BASE}/no-outcome.json")" render_report "$SID" >/dev/null 2>&1 && fail "T7b: expected exit 1" || pass "T7b: missing outcome JSON -> exit 1"
    FRE_INTENT_MD="$(node_path "${TMPDIR_BASE}/no-intent.md")" render_report "$SID" >/dev/null 2>&1 && fail "T7c: expected exit 1" || pass "T7c: missing intent MD -> exit 1"
}

test_T19_render_supervisor_populated() {
    if [ ! -f "$RENDER_JS" ]; then skip "T19 (bin/render-final-report.js missing)"; return; fi
    printf '{"alert":{"cumulative_severity":"warning","findings":[{"categories":["code"],"severity":"warning","detail":"x"}],"findings_surfaced_at":null},"layer1":{"findings":[]},"audit":{"audit_verdict":"CONTINUE"}}\n' > "${TMPDIR_BASE}/t19-sup.json"
    FRE_SUPERVISOR_STATE="$(node_path "${TMPDIR_BASE}/t19-sup.json")" render_report "$SID" 2>/dev/null | grep -qE '<[A-Z_]+>' && fail "T19: TOKEN unresolved" || pass "T19: supervisor state rendered, no TOKEN"
}

test_T20_postmerge_flag_required() {
    if [ ! -f "$RENDER_JS" ]; then skip "T20 (bin/render-final-report.js missing)"; return; fi
    printf '{"PR_NUMBER":"1","PR_TITLE":"T","PR_URL":"","PR_STATE":"MERGED","BRANCH":"b","WORKTREE_PATH":"","CREATED_DATE":"","BACKUP_MANIFEST_PATH":"","NOTES_BACKUP_PATH":"","BRANCH_DELETED":"","CLAUDE_CODE_RESTART_REQUIRED":"","CC_RESTART_REQUIRED":"required","CC_RESTART_REASON":"test-reason","VSCODE_RELOAD_REQUIRED":"","VSCODE_RELOAD_REASON":"","INSTALLER_RERUN_REQUIRED":"","INSTALLER_RERUN_REASON":"","OS_REBOOT_REQUIRED":"","OS_REBOOT_REASON":""}\n' > "${TMPDIR_BASE}/env-t20.json"
    FRE_ENV_JSON="$(node_path "${TMPDIR_BASE}/env-t20.json")" render_report "$SID" 2>/dev/null | grep -qE '<[A-Z_]+>' && fail "T20: TOKEN unresolved" || pass "T20: CC_RESTART_REQUIRED=required rendered, no TOKEN"
}

test_T21_nonempty_outcome_issues() {
    if [ ! -f "$RENDER_JS" ]; then skip "T21 (bin/render-final-report.js missing)"; return; fi
    printf '{"issues":[{"issueNumber":1463,"title":"scriptify","state":"CLOSED","historyEntry":"feature","issueClosed":true,"sentinelsPosted":true,"wipCleared":true}]}\n' > "${TMPDIR_BASE}/outcome-t21.json"
    local out; out="$(FRE_OUTCOME_JSON="$(node_path "${TMPDIR_BASE}/outcome-t21.json")" render_report "$SID" 2>/dev/null)"
    # Scope the assertion to the "### Closed Issue Outcomes" section only —
    # grepping the whole report would also match the unrelated "### Closed
    # Issues" list section, which can independently contain "1463" (e.g. via
    # intent-derived closesIssues content) and mask a broken outcome renderer
    # (see #1614: closedIssueOutcomeLines() field-name mismatch). Same
    # section-scoping idiom as K8 in tests/feature-405-final-report/k-series.sh.
    local region
    region="$(printf '%s\n' "$out" | awk '/^### Closed Issue Outcomes$/{found=1;next} found{if(/^### /){exit}print}')"
    if [ -z "$region" ]; then
        fail "T21: '### Closed Issue Outcomes' section not found in output"
    elif echo "$region" | grep -q '1463' && ! echo "$out" | grep -qE '<[A-Z_]+>'; then
        pass "T21: issue 1463 in Closed Issue Outcomes section, no TOKEN"
    else
        fail "T21: issue missing from Closed Issue Outcomes section or TOKEN unresolved
--- region ---
$region"
    fi
}

# ============ Run all ============

test_T1_render_exists
test_T2_detect_exists
test_T3_sc7_exists
test_T4_render_all_headings
test_T5_no_unresolved_tokens
test_T6_substitution_happened
test_T7_missing_env_exit1
test_T8_invalid_sid_exit1
test_T9_missing_supervisor_ok
test_T7b_T7c_missing_required_files
test_T19_render_supervisor_populated
test_T20_postmerge_flag_required
test_T21_nonempty_outcome_issues

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
