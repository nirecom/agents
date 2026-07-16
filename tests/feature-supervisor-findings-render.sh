#!/usr/bin/env bash
# tests/feature-supervisor-findings-render.sh
# Tests: hooks/lib/supervisor-findings-render.js, hooks/lib/supervisor-report-format.js (CONV_LANG symmetric)
# Tags: supervisor, em-supervisor, findings-render, conv-lang, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - formatLayer2Findings rendered inside a real Claude Code Final Report block
# - CONV_LANG env var propagation across real claude -p hook subprocess boundary
#   (Anthropic bug #27987)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T4: formatLayer2Findings summaryOnly option (Fix 2 / C3)
# T5: CONV_LANG symmetric coverage — formatL2ArmedReason, formatWorktreeOffProposalReason (Fix 3 / C4)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RENDER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-findings-render.js"
FORMAT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js"
CONV_LANG_NODE="$_AGENTS_DIR_NODE/hooks/lib/conv-lang.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if ! command -v node >/dev/null 2>&1; then
    skip "T4/T5-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- T4: formatLayer2Findings summaryOnly option (Fix 2 / C3) ---
# T4a: summaryOnly:false → per-finding detail IS present (GREEN — current behavior)
# T4b: summaryOnly:true → count and severity word present in output
# T4c: summaryOnly:true → individual detail NOT present (RED-EXPECTED until C3 lands)

run_t4_summary_only() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-findings-render.js" ]; then
        skip "T4-all: supervisor-findings-render.js not present"
        return
    fi

    # T4a: summaryOnly:false → per-finding detail line IS present
    local out_full
    out_full=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['workflow'], severity: 'error',   detail: 'unique-detail-alpha', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['code'],    severity: 'warning', detail: 'unique-detail-beta',  reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, {
    sessionId: 't4-sid',
    workflowSessionId: 't4-wsid',
    supervisorPath: '/agents/agents/supervisor.md',
    stateFilePath: '/tmp/state.json',
    summaryOnly: false
});
process.stdout.write(result || '');
" 2>/dev/null)

    if echo "$out_full" | grep -qF "unique-detail-alpha"; then
        pass "T4a: summaryOnly:false → per-finding detail IS present in output"
    else
        fail "T4a: summaryOnly:false → per-finding detail missing (unexpected)"
    fi

    # T4b: summaryOnly:true → count "2" and/or a severity word present
    local out_sum
    out_sum=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['workflow'], severity: 'error',   detail: 'unique-detail-alpha', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['code'],    severity: 'warning', detail: 'unique-detail-beta',  reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, {
    sessionId: 't4-sid',
    workflowSessionId: 't4-wsid',
    supervisorPath: '/agents/agents/supervisor.md',
    stateFilePath: '/tmp/state.json',
    summaryOnly: true
});
process.stdout.write(result || '');
" 2>/dev/null)

    if echo "$out_sum" | grep -qE "2|error|warning"; then
        pass "T4b: summaryOnly:true → count and/or severity word present in output"
    else
        fail "T4b: summaryOnly:true → count and severity word missing from output"
    fi

    # T4c: summaryOnly:true → individual finding detail NOT present (RED-EXPECTED until C3 lands)
    if echo "$out_sum" | grep -qF "unique-detail-alpha"; then
        fail "T4c [RED-EXPECTED]: summaryOnly:true still emits per-finding detail (summaryOnly option not yet implemented)"
    else
        pass "T4c: summaryOnly:true → individual finding detail NOT in output"
    fi

    # T4d (GREEN-guard): summaryOnly:true emits EXACTLY the canonical one-line format
    #   [EM Supervisor] N finding(s), highest severity: X.
    # Precise format check (T4b's "2|error|warning" is too loose to catch drift).
    if echo "$out_sum" | grep -qE '^\[EM Supervisor\] [0-9]+ finding\(s\), highest severity: '; then
        pass "T4d: summaryOnly:true → canonical '[EM Supervisor] N finding(s), highest severity: X.' format"
    else
        fail "T4d: summaryOnly:true output does not match canonical one-line format, got: $(printf '%q' "$out_sum")"
    fi
}

# --- T5: CONV_LANG symmetric coverage for formatL2ArmedReason, formatWorktreeOffProposalReason (Fix 3 / C4) ---
# T5a: CONV_LANG=ja → formatL2ArmedReason starts with injection prefix (RED-EXPECTED)
# T5b: CONV_LANG=ja → formatWorktreeOffProposalReason starts with injection prefix (RED-EXPECTED)
# T5c: CONV_LANG=english → formatL2ArmedReason does NOT add prefix (GREEN)
# T5d: CONV_LANG=english → formatWorktreeOffProposalReason does NOT add prefix (GREEN)

run_t5_conv_lang_symmetric() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-report-format.js" ]; then
        skip "T5-all: supervisor-report-format.js not present"
        return
    fi
    if [ ! -f "$AGENTS_DIR/hooks/lib/conv-lang.js" ]; then
        skip "T5-all: conv-lang.js not present"
        return
    fi

    # T5a: CONV_LANG=ja → formatL2ArmedReason starts with injection prefix (RED-EXPECTED)
    local out_l2 injection_ja result_l2
    out_l2=$(CONV_LANG=ja run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const { getConvLangInjection } = require('$CONV_LANG_NODE');
const result = fmt.formatL2ArmedReason(
    'C2', 'test-sid-l2', 'test-wsid',
    '/agents/agents/supervisor.md', '/tmp/state.json', 'test-sid-l2'
);
const injection = getConvLangInjection();
process.stdout.write(JSON.stringify({ result, injection }));
" 2>/dev/null)

    injection_ja=$(echo "$out_l2" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).injection || '')" 2>/dev/null)
    result_l2=$(echo "$out_l2" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).result || '')" 2>/dev/null)

    if [ -z "$injection_ja" ]; then
        skip "T5a: CONV_LANG=ja getConvLangInjection returned null/empty (may not propagate)"
    elif [[ "$result_l2" == "$injection_ja"* ]]; then
        pass "T5a: CONV_LANG=ja → formatL2ArmedReason starts with injection prefix"
    else
        fail "T5a [RED-EXPECTED]: CONV_LANG=ja formatL2ArmedReason does NOT start with injection prefix (CONV_LANG not yet applied)"
    fi

    # T5b: CONV_LANG=ja → formatWorktreeOffProposalReason starts with injection prefix (RED-EXPECTED)
    local out_wt injection_wt result_wt
    out_wt=$(CONV_LANG=ja run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const { getConvLangInjection } = require('$CONV_LANG_NODE');
const result = fmt.formatWorktreeOffProposalReason(
    'test-sid-wt', 'test-wsid',
    '/agents/agents/supervisor.md', '/tmp/state.json', 'test-sid-wt'
);
const injection = getConvLangInjection();
process.stdout.write(JSON.stringify({ result, injection }));
" 2>/dev/null)

    injection_wt=$(echo "$out_wt" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).injection || '')" 2>/dev/null)
    result_wt=$(echo "$out_wt" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).result || '')" 2>/dev/null)

    if [ -z "$injection_wt" ]; then
        skip "T5b: CONV_LANG=ja getConvLangInjection returned null/empty (may not propagate)"
    elif [[ "$result_wt" == "$injection_wt"* ]]; then
        pass "T5b: CONV_LANG=ja → formatWorktreeOffProposalReason starts with injection prefix"
    else
        fail "T5b [RED-EXPECTED]: CONV_LANG=ja formatWorktreeOffProposalReason does NOT start with injection prefix (CONV_LANG not yet applied)"
    fi

    # T5c: CONV_LANG=english → formatL2ArmedReason does NOT add prefix (GREEN — current behavior)
    local out_l2_en
    out_l2_en=$(CONV_LANG=english run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const result = fmt.formatL2ArmedReason(
    'C2', 'sid-en', 'wsid-en', '/sup.md', '/st.json', 'sid-en'
);
process.stdout.write(result.startsWith('[EM Supervisor]') ? 'no-prefix' : 'has-prefix');
" 2>/dev/null)

    if [ "$out_l2_en" = "has-prefix" ]; then
        fail "T5c: CONV_LANG=english formatL2ArmedReason should NOT add injection prefix"
    else
        pass "T5c: CONV_LANG=english → formatL2ArmedReason has no injection prefix"
    fi

    # T5d: CONV_LANG=english → formatWorktreeOffProposalReason does NOT add prefix (GREEN)
    local out_wt_en
    out_wt_en=$(CONV_LANG=english run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const result = fmt.formatWorktreeOffProposalReason(
    'sid-en', 'wsid-en', '/sup.md', '/st.json', 'sid-en'
);
process.stdout.write(result.startsWith('[EM Supervisor]') ? 'no-prefix' : 'has-prefix');
" 2>/dev/null)

    if [ "$out_wt_en" = "has-prefix" ]; then
        fail "T5d: CONV_LANG=english formatWorktreeOffProposalReason should NOT add injection prefix"
    else
        pass "T5d: CONV_LANG=english → formatWorktreeOffProposalReason has no injection prefix"
    fi
}

run_t4_summary_only
run_t5_conv_lang_symmetric

# --- C3: formatLayer2Findings with forFinalReport:true ---
# T6a: returns non-null when findings array is non-empty (has content to show)
# T6b: output still contains a findings summary line (not empty/null)
# T6c: forFinalReport:true → `<` characters in detail are escaped to U+2039 (‹)
# T6d: forFinalReport:true suppresses the footer lines (no "Session ID:", "Full audit trail:")
run_c3_for_final_report() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-findings-render.js" ]; then
        skip "C3-forFinalReport: supervisor-findings-render.js not present"
        return
    fi

    # Seed findings with a detail containing `<` that should be escaped
    local out_final
    out_final=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    {
        categories: ['workflow'],
        severity: 'error',
        detail: 'detail with <angle> brackets',
        reporter: 'test',
        timestamp: new Date().toISOString()
    },
    {
        categories: ['code'],
        severity: 'warning',
        detail: 'another finding',
        reporter: 'test',
        timestamp: new Date().toISOString()
    }
];
const result = r.formatLayer2Findings(findings, {
    sessionId: 'c3-sid',
    workflowSessionId: 'c3-wsid',
    supervisorPath: '/agents/agents/supervisor.md',
    stateFilePath: '/tmp/state.json',
    forFinalReport: true
});
process.stdout.write(result === null ? 'NULL' : result);
" 2>/dev/null)

    # T6a: must return non-null for non-empty findings
    if [ "$out_final" = "NULL" ]; then
        fail "C3-T6a: formatLayer2Findings with forFinalReport:true returned null for non-empty findings"
        return
    else
        pass "C3-T6a: forFinalReport:true → non-null result for non-empty findings"
    fi

    # T6b: output contains a findings summary line (starts with [EM Supervisor])
    if echo "$out_final" | grep -q "\[EM Supervisor\]"; then
        pass "C3-T6b: forFinalReport:true → output contains [EM Supervisor] summary line"
    else
        fail "C3-T6b: forFinalReport:true → [EM Supervisor] summary line missing from output"
    fi

    # T6c: `<` in detail is escaped to U+2039 (‹) — the raw < must NOT appear in a finding detail context
    # The escapeTokens function replaces < with ‹ (U+2039)
    if echo "$out_final" | node -e "
const data = require('fs').readFileSync(0, 'utf8');
// Check that U+2039 appears (escaped form) and raw < does not appear in detail output
const hasEscaped = data.includes('‹angle›') || data.includes('‹angle');
const hasRaw = data.includes('<angle>');
process.exit(hasEscaped && !hasRaw ? 0 : 1);
" 2>/dev/null; then
        pass "C3-T6c: forFinalReport:true → < escaped to U+2039 (‹) in finding detail"
    else
        fail "C3-T6c: forFinalReport:true → < not properly escaped in finding detail (got: $(printf '%q' "${out_final:0:100}"))"
    fi

    # T6d: forFinalReport:true suppresses footer lines (no "Session ID:" or "Full audit trail:")
    if echo "$out_final" | grep -q "Session ID:"; then
        fail "C3-T6d: forFinalReport:true must suppress 'Session ID:' footer line"
    elif echo "$out_final" | grep -q "Full audit trail:"; then
        fail "C3-T6d: forFinalReport:true must suppress 'Full audit trail:' footer line"
    else
        pass "C3-T6d: forFinalReport:true → footer lines (Session ID, Full audit trail) suppressed"
    fi
}
run_c3_for_final_report

# --- T7: formatLayer2Findings actionableOnly option ---
# T7a: all-notice findings → output equals/contains "no actionable findings" fallback sentence (RED-EXPECTED)
# T7b: mixed error/warning/notice → error/warning details present, notice detail absent (RED-EXPECTED)
# T7c: empty array → result is null (existing early-return behavior; assert NULL sentinel) (GREEN)
# T7d: 2 warning/error findings → every non-empty output line starts with [EM Supervisor] (RED-EXPECTED)
# T7e: classifier both-verdicts — workflow→/issue-create signal; code→no /issue-create signal (RED-EXPECTED)

run_t7_actionable_only() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-findings-render.js" ]; then
        skip "T7-all: supervisor-findings-render.js not present"
        return
    fi

    # T7a: all-notice findings → fallback sentence (actionableOnly filters them out → zero actionable)
    # RED-EXPECTED: actionableOnly mode not yet implemented; current code returns verbose listing
    local out_notice
    out_notice=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['other'], severity: 'notice', detail: 'notice-only-detail-alpha', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['env'],   severity: 'notice', detail: 'notice-only-detail-beta',  reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, { actionableOnly: true });
process.stdout.write(result === null ? 'NULL' : result);
" 2>/dev/null)

    if echo "$out_notice" | grep -qi "no actionable findings"; then
        pass "T7a: actionableOnly + all-notice → fallback 'no actionable findings' sentence"
    else
        fail "T7a [RED-EXPECTED]: actionableOnly + all-notice → 'no actionable findings' not returned (actionableOnly not yet implemented); got: $(printf '%q' "${out_notice:0:100}")"
    fi

    # T7b: mixed → error/warning present, unique notice detail absent
    # RED-EXPECTED: actionableOnly not yet implemented
    local out_mixed notice_token="UNIQUE-NOTICE-DETAIL-BETA-99"
    out_mixed=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['code'],  severity: 'error',   detail: 'error-detail-gamma',    reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['workflow'], severity: 'warning', detail: 'warning-detail-delta', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['other'], severity: 'notice',  detail: 'UNIQUE-NOTICE-DETAIL-BETA-99', reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, { actionableOnly: true });
process.stdout.write(result === null ? 'NULL' : result);
" 2>/dev/null)

    local t7b_ok=1
    if ! echo "$out_mixed" | grep -q "error-detail-gamma"; then
        fail "T7b [RED-EXPECTED]: actionableOnly → error detail 'error-detail-gamma' missing (actionableOnly not yet implemented)"
        t7b_ok=0
    fi
    if ! echo "$out_mixed" | grep -q "warning-detail-delta"; then
        fail "T7b [RED-EXPECTED]: actionableOnly → warning detail 'warning-detail-delta' missing (actionableOnly not yet implemented)"
        t7b_ok=0
    fi
    if echo "$out_mixed" | grep -q "$notice_token"; then
        fail "T7b [RED-EXPECTED]: actionableOnly → notice detail '$notice_token' must be filtered out (actionableOnly not yet implemented)"
        t7b_ok=0
    fi
    if [ "$t7b_ok" -eq 1 ]; then
        pass "T7b: actionableOnly + mixed → error/warning details present, notice detail absent"
    fi

    # T7c: empty array → result is null (existing early-return at line 33 fires before actionableOnly branch)
    # This must be GREEN now (the early return already handles [])
    local out_empty
    out_empty=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const result = r.formatLayer2Findings([], { actionableOnly: true });
process.stdout.write(result === null ? 'NULL' : String(result));
" 2>/dev/null)

    if [ "$out_empty" = "NULL" ]; then
        pass "T7c: actionableOnly + empty array → null (existing early-return behavior, GREEN)"
    else
        fail "T7c: actionableOnly + [] → expected null (NULL sentinel), got: $(printf '%q' "${out_empty:0:80}")"
    fi

    # T7d: 2 warning/error findings → every non-empty output line starts with [EM Supervisor]
    # RED-EXPECTED: actionableOnly not yet implemented; current code produces multi-line verbose output
    local out_prefix
    out_prefix=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['code'], severity: 'error',   detail: 'detail-epsilon', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['env'],  severity: 'warning', detail: 'detail-zeta',    reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, { actionableOnly: true });
process.stdout.write(result === null ? 'NULL' : result);
" 2>/dev/null)

    if [ "$out_prefix" = "NULL" ]; then
        fail "T7d [RED-EXPECTED]: actionableOnly returned null for non-empty error/warning findings"
    else
        # Check that every non-empty line starts with [EM Supervisor]
        local bad_line
        bad_line=$(echo "$out_prefix" | grep -v "^\[EM Supervisor\]" | grep -v "^$" | head -1)
        if [ -z "$bad_line" ]; then
            pass "T7d: actionableOnly → every non-empty output line starts with [EM Supervisor]"
        else
            fail "T7d [RED-EXPECTED]: actionableOnly → line not starting with [EM Supervisor]: $(printf '%q' "${bad_line:0:100}")"
        fi
    fi

    # T7e: classifier both-verdicts
    # workflow category → /issue-create signal present; code category → /issue-create signal absent
    # RED-EXPECTED: actionableOnly not yet implemented
    local out_classifier
    out_classifier=$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
    { categories: ['workflow'], severity: 'warning', detail: 'wf-detail', reporter: 'test', timestamp: new Date().toISOString() },
    { categories: ['code'],    severity: 'warning', detail: 'cd-detail', reporter: 'test', timestamp: new Date().toISOString() }
];
const result = r.formatLayer2Findings(findings, { actionableOnly: true });
process.stdout.write(result === null ? 'NULL' : result);
" 2>/dev/null)

    if [ "$out_classifier" = "NULL" ]; then
        fail "T7e [RED-EXPECTED]: actionableOnly returned null for non-empty findings"
    else
        local wf_line code_line
        wf_line=$(echo "$out_classifier" | grep "workflow")
        code_line=$(echo "$out_classifier" | grep "code")

        local t7e_ok=1
        if [ -z "$wf_line" ]; then
            fail "T7e [RED-EXPECTED]: workflow finding line not present in actionableOnly output"
            t7e_ok=0
        elif ! echo "$wf_line" | grep -q "/issue-create"; then
            fail "T7e [RED-EXPECTED]: workflow line must contain /issue-create signal, got: $(printf '%q' "${wf_line:0:150}")"
            t7e_ok=0
        fi
        if [ -z "$code_line" ]; then
            fail "T7e [RED-EXPECTED]: code finding line not present in actionableOnly output"
            t7e_ok=0
        elif echo "$code_line" | grep -q "/issue-create"; then
            fail "T7e [RED-EXPECTED]: code line must NOT contain /issue-create signal, got: $(printf '%q' "${code_line:0:150}")"
            t7e_ok=0
        fi
        if [ "$t7e_ok" -eq 1 ]; then
            pass "T7e: classifier both-verdicts — workflow→/issue-create, code→no /issue-create"
        fi
    fi
}

run_t7_actionable_only

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
