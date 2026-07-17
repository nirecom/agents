#!/bin/bash
# tests/feature-1463-session-close-scriptify.sh
# Tests: bin/render-final-report.js, bin/session-close-detect-wf-meta.js, bin/session-close-render-sc7.js, hooks/lib/final-report-schema.js, hooks/stop-final-report-guard.js, skills/session-close/SKILL.md
# Tags: scope:issue-specific
#
# Issue #1463 — scriptify session-close/SKILL.md.
# The SC-6 Final Report emit and its `node -e` helpers move out of SKILL.md into
# three bin/ scripts. This suite verifies those scripts render the full Final
# Report with no unresolved guard tokens, plus structural assertions on SKILL.md.
#
# L3 gap (what this test does NOT catch):
# - actual LLM verbatim emit of the Final Report in a real claude -p session
# - stop-final-report-guard.js firing on real transcript
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# TDD note: bin/render-final-report.js, bin/session-close-detect-wf-meta.js, and
# bin/session-close-render-sc7.js do NOT exist until the write-code step. T1-T12
# and S1-S7 FAIL until then — that is expected.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}
AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

RENDER_JS="${AGENTS_DIR}/bin/render-final-report.js"
DETECT_JS="${AGENTS_DIR}/bin/session-close-detect-wf-meta.js"
SC7_JS="${AGENTS_DIR}/bin/session-close-render-sc7.js"
SKILL_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"
GUARD_JS="${AGENTS_DIR}/hooks/stop-final-report-guard.js"

PASS=0
FAIL=0
SKIP=0
unset AGENTS_CONFIG_DIR

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# ---- fixtures ---------------------------------------------------------------
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f1463-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SID="f1463-session"
ENV_JSON="${TMPDIR_BASE}/${SID}-final-report-env.json"
OUTCOME_JSON="${TMPDIR_BASE}/${SID}-issue-close-outcome.json"
INTENT_MD="${TMPDIR_BASE}/${SID}-intent.md"

# Known sentinel values used for substitution assertions (T6).
FIXTURE_PR_TITLE="Fixture PR Title 1463"
FIXTURE_BRANCH="feature/fixture-1463"

# env JSON mirrors the shape written by bin/session-close-build-env.js.
cat > "$ENV_JSON" <<EOF
{
  "PR_NUMBER": "999",
  "PR_TITLE": "${FIXTURE_PR_TITLE}",
  "PR_URL": "https://example.com/pr/999",
  "PR_STATE": "MERGED",
  "BRANCH": "${FIXTURE_BRANCH}",
  "WORKTREE_PATH": "",
  "CREATED_DATE": "",
  "BACKUP_MANIFEST_PATH": "",
  "NOTES_BACKUP_PATH": "",
  "BRANCH_DELETED": "",
  "CLAUDE_CODE_RESTART_REQUIRED": "",
  "CC_RESTART_REQUIRED": "",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "",
  "OS_REBOOT_REASON": ""
}
EOF

printf '{"issues":[]}\n' > "$OUTCOME_JSON"

cat > "$INTENT_MD" <<'EOF'
# Intent

## Issues
- #1463: scriptify session-close SKILL.md

## Scope
Test fixture intent.
EOF

ENV_JSON_NODE="$(node_path "$ENV_JSON")"
OUTCOME_JSON_NODE="$(node_path "$OUTCOME_JSON")"
INTENT_MD_NODE="$(node_path "$INTENT_MD")"

# render-final-report.js CLI contract is not yet frozen; drive it via the two
# argument styles the SKILL.md notes describe (positional paths + env vars).
# The test passes both so it survives either final signature.
render_report() {
    # $1 = session-id ; env overrides applied by caller
    run_with_timeout 120 env \
        FINAL_REPORT_ENV_JSON="${FRE_ENV_JSON:-$ENV_JSON_NODE}" \
        OUTCOME_JSON="${FRE_OUTCOME_JSON:-$OUTCOME_JSON_NODE}" \
        INTENT_MD="${FRE_INTENT_MD:-$INTENT_MD_NODE}" \
        SUPERVISOR_STATE_JSON="${FRE_SUPERVISOR_STATE:-}" \
        node "$RENDER_JS" \
        "$1" \
        "${FRE_ENV_JSON:-$ENV_JSON_NODE}" \
        "${FRE_OUTCOME_JSON:-$OUTCOME_JSON_NODE}" \
        "${FRE_INTENT_MD:-$INTENT_MD_NODE}" \
        "${FRE_SUPERVISOR_STATE:-}"
}

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

test_T10_T11_no_args_exit1() {
    if [ ! -f "$DETECT_JS" ] || [ ! -f "$SC7_JS" ]; then skip "T10+T11 (arg-guard scripts missing)"; return; fi
    run_with_timeout 120 node "$DETECT_JS" >/dev/null 2>&1; local c1=$?
    run_with_timeout 120 node "$SC7_JS" >/dev/null 2>&1; local c2=$?
    if [ "$c1" = "1" ]; then pass "T10: detect no-args -> exit 1"; else fail "T10: expected exit 1, got $c1"; fi
    if [ "$c2" = "1" ]; then pass "T11: sc7 no-args -> exit 1"; else fail "T11: expected exit 1, got $c2"; fi
}

# T12: sc7 with nonexistent state path -> exit 0, empty stdout (fail-open: nothing to surface).
test_T12_sc7_absent_path_empty() {
    if [ ! -f "$SC7_JS" ]; then
        skip "T12_sc7_absent_path_empty (bin/session-close-render-sc7.js missing)"
        return
    fi
    local out code
    out="$(run_with_timeout 120 node "$SC7_JS" "${TMPDIR_BASE}/absent-supervisor-state.json" 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "T12_sc7_absent_path_empty: absent state path -> exit 0, empty stdout"
    else
        fail "T12_sc7_absent_path_empty: expected exit 0 + empty stdout, got exit $code, out='$out'"
    fi
}

# ============ S1-S7: structural assertions ============

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

# ============ T13-T18: detect-wf-meta + sc7 variants ============
test_T13_detect_wf_meta_yes() {
    if [ ! -f "$DETECT_JS" ]; then skip "T13_detect_wf_meta_yes (bin/session-close-detect-wf-meta.js missing)"; return; fi
    mkdir -p "${TMPDIR_BASE}/wf-state"
    printf '{"workflow_type":"wf-meta","steps":{}}\n' > "${TMPDIR_BASE}/wf-state/t13.json"
    local out; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" t13 2>/dev/null)"
    if [ "$out" = "yes" ]; then pass "T13_detect_wf_meta_yes: wf-meta state -> 'yes'"; else fail "T13_detect_wf_meta_yes: expected 'yes', got '$out'"; fi
}
test_T14_detect_wf_meta_no() {
    if [ ! -f "$DETECT_JS" ]; then skip "T14_detect_wf_meta_no (bin/session-close-detect-wf-meta.js missing)"; return; fi
    printf '{"workflow_type":"wf-code","steps":{}}\n' > "${TMPDIR_BASE}/wf-state/t14.json"
    local out; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" t14 2>/dev/null)"
    if [ "$out" = "no" ]; then pass "T14_detect_wf_meta_no: wf-code state -> 'no'"; else fail "T14_detect_wf_meta_no: expected 'no', got '$out'"; fi
}
test_T17_detect_no_state() {
    if [ ! -f "$DETECT_JS" ]; then skip "T17_detect_no_state (bin/session-close-detect-wf-meta.js missing)"; return; fi
    local out code; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" no-state-t17 2>/dev/null)"; code=$?
    if [ "$out" = "no" ] && [ "$code" = "0" ]; then pass "T17_detect_no_state: missing state -> 'no', exit 0"; else fail "T17_detect_no_state: expected 'no'/exit 0, got '$out'/exit $code"; fi
}
test_T15_T18_sc7_variants() {
    if [ ! -f "$SC7_JS" ]; then skip "T15_T18_sc7_variants (bin/session-close-render-sc7.js missing)"; return; fi
    local sf="${TMPDIR_BASE}/sc7-t15.json" out
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"test"}],"findings_surfaced_at":null},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$(node_path "$sf")" "$SID" 2>/dev/null)"
    if [ -z "$out" ]; then fail "T15_T18_sc7_variants: T15 unsurfaced expected non-empty stdout, got empty"; return; fi
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"t"}],"findings_surfaced_at":"2026-01-01T00:00:00Z"},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$(node_path "$sf")" "$SID" 2>/dev/null)"
    if [ -z "$out" ]; then pass "T15_T18_sc7_variants: unsurfaced->non-empty, already-surfaced->empty"; else fail "T15_T18_sc7_variants: T18 already-surfaced expected empty stdout, got '$out'"; fi
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
    printf '{"issues":[{"number":1463,"title":"scriptify","state":"CLOSED","historyEntry":"feature","issueClosed":true,"sentinelsPosted":true,"wipCleared":true}]}\n' > "${TMPDIR_BASE}/outcome-t21.json"
    local out; out="$(FRE_OUTCOME_JSON="$(node_path "${TMPDIR_BASE}/outcome-t21.json")" render_report "$SID" 2>/dev/null)"
    echo "$out" | grep -q '1463' && ! echo "$out" | grep -qE '<[A-Z_]+>' && pass "T21: issue 1463 in output, no TOKEN" || fail "T21: issue missing or TOKEN unresolved"
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
test_T10_T11_no_args_exit1
test_T12_sc7_absent_path_empty
test_T7b_T7c_missing_required_files
test_T19_render_supervisor_populated
test_S1_skill_no_node_e
test_S2_skill_under_200_lines
test_S3_skill_refs_render
test_S4_skill_refs_detect
test_S5_skill_refs_sc7
test_S6_render_requires_schema
test_S7_guard_no_local_postmerge
test_T13_detect_wf_meta_yes
test_T14_detect_wf_meta_no
test_T17_detect_no_state
test_T15_T18_sc7_variants
test_T20_postmerge_flag_required
test_T21_nonempty_outcome_issues

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
