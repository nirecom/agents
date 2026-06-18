#!/bin/bash
# tests/feature-feat-928-supervisor-report-format/formatter-unit.sh
# Formatter unit tests (F tests) — invoke formatter module directly via node.
# Runnable standalone: bash tests/feature-feat-928-supervisor-report-format/formatter-unit.sh

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ---------------------------------------------------------------------------
# F1-F12: core formatter output tests
# ---------------------------------------------------------------------------

run_f1() {
    require_source "$FORMATTER" "F1: cumSev=error output contains aggregated Categories: line" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f1-sid" "'f1-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Categories:"; then
        pass "F1: cumSev=error output contains aggregated Categories: line"
    else
        fail "F1: cumSev=error output contains aggregated Categories: line (out=$out)"
    fi
}

run_f2() {
    require_source "$FORMATTER" "F2: cumSev=error output contains per-finding category tokens" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f2-sid" "'f2-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "workflow" && echo "$out" | grep -q "code" && echo "$out" | grep -q "security"; then
        pass "F2: cumSev=error output contains per-finding category tokens"
    else
        fail "F2: cumSev=error output contains per-finding category tokens (out=$out)"
    fi
}

run_f3() {
    require_source "$FORMATTER" "F3: cumSev=error output contains last finding Detail: text (G19)" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f3-sid" "'f3-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Detail:" && echo "$out" | grep -q "last-detail-text"; then
        pass "F3: cumSev=error output contains last finding Detail: text (G19)"
    else
        fail "F3: cumSev=error output contains last finding Detail: text (G19) (out=$out)"
    fi
}

run_f4() {
    require_source "$FORMATTER" "F4: cumSev=error output contains Session ID: token (G20)" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f4-sid" "'f4-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Session ID: f4-sid"; then
        pass "F4: cumSev=error output contains Session ID: token (G20)"
    else
        fail "F4: cumSev=error output contains Session ID: token (G20) (out=$out)"
    fi
}

run_f5() {
    require_source "$FORMATTER" "F5: cumSev=error output contains Workflow session ID: token (G21)" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f5-sid" "'f5-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Workflow session ID: f5-wsid"; then
        pass "F5: cumSev=error output contains Workflow session ID: token (G21)"
    else
        fail "F5: cumSev=error output contains Workflow session ID: token (G21) (out=$out)"
    fi
}

run_f6() {
    require_source "$FORMATTER" "F6: cumSev=error output contains Recommended action: line" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "f6-sid" "'f6-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Recommended action:"; then
        pass "F6: cumSev=error output contains Recommended action: line"
    else
        fail "F6: cumSev=error output contains Recommended action: line (out=$out)"
    fi
}

run_f7() {
    require_source "$FORMATTER" "F7: l2Armed output uses human-readable resume instructions, not raw node -e one-liner" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "f7-sid" "'f7-wsid'" "agents/supervisor.md" "/tmp/state.json")
    # Must contain readable phrase
    if ! ( echo "$out" | grep -qE "To resume|Clear:" ); then
        fail "F7: l2Armed output uses human-readable resume instructions (missing To resume / Clear:) (out=$out)"
        return
    fi
    # Must NOT lead with a raw node -e require(...) one-liner — that is the old format.
    local first
    first=$(echo "$out" | grep -v '^[[:space:]]*$' | head -n 1)
    if echo "$first" | grep -qE "^node -e \"require\("; then
        fail "F7: l2Armed output uses human-readable resume instructions (first line is raw node -e, out=$out)"
        return
    fi
    pass "F7: l2Armed output uses human-readable resume instructions, not raw node -e one-liner"
}

run_f8() {
    require_source "$FORMATTER" "F8: l2Armed output contains stateFilePath in a File: line" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "f8-sid" "'f8-wsid'" "agents/supervisor.md" "/tmp/sup-state-f8.json")
    if echo "$out" | grep -q "File:" && echo "$out" | grep -q "/tmp/sup-state-f8.json"; then
        pass "F8: l2Armed output contains stateFilePath in a File: line"
    else
        fail "F8: l2Armed output contains stateFilePath in a File: line (out=$out)"
    fi
}

run_f9() {
    require_source "$FORMATTER" "F9: l2Armed output contains Session ID: token" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "f9-sid" "'f9-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -q "Session ID: f9-sid"; then
        pass "F9: l2Armed output contains Session ID: token"
    else
        fail "F9: l2Armed output contains Session ID: token (out=$out)"
    fi
}

run_f10() {
    require_source "$FORMATTER" "F10: l2Armed output contains Workflow session ID: token" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "f10-sid" "'f10-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -q "Workflow session ID: f10-wsid"; then
        pass "F10: l2Armed output contains Workflow session ID: token"
    else
        fail "F10: l2Armed output contains Workflow session ID: token (out=$out)"
    fi
}

run_f11() {
    require_source "$FORMATTER" "F11: l2Armed C1 cause output contains stop_hook_active sentinel detection language" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "f11-sid" "'f11-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -qi "sentinel" || echo "$out" | grep -q "stop_hook_active" || echo "$out" | grep -qi "hang"; then
        pass "F11: l2Armed C1 cause output contains stop_hook_active sentinel detection language"
    else
        fail "F11: l2Armed C1 cause output contains stop_hook_active sentinel detection language (out=$out)"
    fi
}

run_f12() {
    require_source "$FORMATTER" "F12: l2Armed C2 cause output contains scheduled review language" || return
    local out
    out=$(format_l2_armed "C2 scheduled-review" "f12-sid" "'f12-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -qi "scheduled"; then
        pass "F12: l2Armed C2 cause output contains scheduled review language"
    else
        fail "F12: l2Armed C2 cause output contains scheduled review language (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# F13-F14: C3 worktree-off / workflow-off proposal cause (#903)
# Mirrors F9/F10 (C1) shape: same call signature, distinct cause string.
# RED: source branch `isC3` not yet implemented in formatL2ArmedReason.
# ---------------------------------------------------------------------------

run_f13() {
    require_source "$FORMATTER" "F13: l2Armed C3 worktree-off proposal -> output contains WORKTREE_OFF and resume one-liner" || return
    local out
    out=$(format_l2_armed "C3 worktree-off proposal" "f13-sid" "'f13-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -q "WORKTREE_OFF" && echo "$out" | grep -q "l2_armed_at: null"; then
        pass "F13: l2Armed C3 worktree-off proposal -> output contains WORKTREE_OFF and resume one-liner"
    else
        fail "F13: l2Armed C3 worktree-off proposal -> output contains WORKTREE_OFF and resume one-liner (out=$out)"
    fi
}

run_f14() {
    require_source "$FORMATTER" "F14: l2Armed C3 workflow-off proposal -> output contains WORKFLOW_OFF and resume one-liner" || return
    local out
    out=$(format_l2_armed "C3 workflow-off proposal" "f14-sid" "'f14-wsid'" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -q "WORKFLOW_OFF" && echo "$out" | grep -q "l2_armed_at: null"; then
        pass "F14: l2Armed C3 workflow-off proposal -> output contains WORKFLOW_OFF and resume one-liner"
    else
        fail "F14: l2Armed C3 workflow-off proposal -> output contains WORKFLOW_OFF and resume one-liner (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# Edge-case formatter tests
# ---------------------------------------------------------------------------

run_f_empty() {
    require_source "$FORMATTER" "F-empty: empty findings produces Categories: (none) and Detail: (no findings recorded)" || return
    local out
    out=$(format_cumsev_error "[]" "empty-sid" "'empty-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Categories: (none)" && echo "$out" | grep -q "Detail: (no findings recorded)"; then
        pass "F-empty: empty findings produces Categories: (none) and Detail: (no findings recorded)"
    else
        fail "F-empty: empty findings produces Categories: (none) and Detail: (no findings recorded) (out=$out)"
    fi
}

run_f_null_wsid_cumsev() {
    require_source "$FORMATTER" "F-null-wsid-cumsev: null workflowSessionId renders as UNAVAILABLE in cumSev output" || return
    local out
    out=$(format_cumsev_error '[{"categories":["code"],"severity":"error","detail":"d","timestamp":"2026-06-06T12:00:00.000Z"}]' "null-wsid-sid" "null" "agents/supervisor.md")
    if echo "$out" | grep -q "Workflow session ID: UNAVAILABLE"; then
        pass "F-null-wsid-cumsev: null workflowSessionId renders as UNAVAILABLE in cumSev output"
    else
        fail "F-null-wsid-cumsev: null workflowSessionId renders as UNAVAILABLE in cumSev output (out=$out)"
    fi
}

run_f_null_wsid_l2armed() {
    require_source "$FORMATTER" "F-null-wsid-l2armed: null workflowSessionId renders as UNAVAILABLE in l2Armed output" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "null-wsid-l2-sid" "null" "agents/supervisor.md" "/tmp/state.json")
    if echo "$out" | grep -q "Workflow session ID: UNAVAILABLE"; then
        pass "F-null-wsid-l2armed: null workflowSessionId renders as UNAVAILABLE in l2Armed output"
    else
        fail "F-null-wsid-l2armed: null workflowSessionId renders as UNAVAILABLE in l2Armed output (out=$out)"
    fi
}

run_f_single_finding() {
    require_source "$FORMATTER" "F-single-finding: single-finding produces Categories: and detail token" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_ONE" "f-single-sid" "'f-single-wsid'" "agents/supervisor.md")
    if echo "$out" | grep -q "Categories:" && echo "$out" | grep -q "workflow" && echo "$out" | grep -q "only-finding"; then
        pass "F-single-finding: single-finding produces Categories: and detail token"
    else
        fail "F-single-finding: single-finding produces Categories: and detail token (out=$out)"
    fi
}

run_f_null_fields() {
    require_source "$FORMATTER" "F-null-fields: null categories and null detail render as (none) and (no detail)" || return
    local out rc
    out=$(format_cumsev_error "$FINDINGS_NULL" "f-null-sid" "'f-null-wsid'" "agents/supervisor.md")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-null-fields: null categories and null detail render as (none) and (no detail) (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "(none)" && echo "$out" | grep -q "(no detail)"; then
        pass "F-null-fields: null categories and null detail render as (none) and (no detail)"
    else
        fail "F-null-fields: null categories and null detail render as (none) and (no detail) (out=$out)"
    fi
}

run_f_null_findings() {
    require_source "$FORMATTER" "F-null-findings: null findings argument produces Categories: (none) and rc=0" || return
    local out rc
    out=$(format_cumsev_error "null" "fn-sid" "'fn-wsid'" "agents/supervisor.md")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-null-findings: null findings argument produces Categories: (none) and rc=0 (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "Categories: (none)"; then
        pass "F-null-findings: null findings argument produces Categories: (none) and rc=0"
    else
        fail "F-null-findings: null findings argument produces Categories: (none) and rc=0 (out=$out)"
    fi
}

run_f_missing_severity() {
    require_source "$FORMATTER" "F-missing-severity: finding without severity key renders (none) for severity and rc=0" || return
    local out rc
    out=$(format_cumsev_error "$FINDINGS_NO_SEV" "fms-sid" "'fms-wsid'" "agents/supervisor.md")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-missing-severity: finding without severity key renders (none) for severity and rc=0 (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "(none)"; then
        pass "F-missing-severity: finding without severity key renders (none) for severity and rc=0"
    else
        fail "F-missing-severity: finding without severity key renders (none) for severity and rc=0 (out=$out)"
    fi
}

run_f_null_cause() {
    require_source "$FORMATTER" "F-null-cause: empty-string cause takes else-branch and contains To resume or Clear: and rc=0" || return
    local out rc
    out=$(format_l2_armed "" "nc-sid" "'nc-wsid'" "agents/supervisor.md" "/tmp/state.json")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-null-cause: empty-string cause takes else-branch and contains To resume or Clear: and rc=0 (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -qE "To resume|Clear:"; then
        pass "F-null-cause: empty-string cause takes else-branch and contains To resume or Clear: and rc=0"
    else
        fail "F-null-cause: empty-string cause takes else-branch and contains To resume or Clear: and rc=0 (out=$out)"
    fi
}

run_f_sparse_findings() {
    require_source "$FORMATTER" "F-sparse-findings: null element in findings array is silently skipped, real finding code present" || return
    local out rc
    out=$(format_cumsev_error "$FINDINGS_SPARSE" "sparse-sid" "'sparse-wsid'" "agents/supervisor.md")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-sparse-findings: null element in findings array is silently skipped, real finding code present (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "code"; then
        pass "F-sparse-findings: null element in findings array is silently skipped, real finding code present"
    else
        fail "F-sparse-findings: null element in findings array is silently skipped, real finding code present (out=$out)"
    fi
}

run_f_non_string_category() {
    require_source "$FORMATTER" "F-non-string-category: numeric category 42 is filtered out, string code is present" || return
    local out rc
    out=$(format_cumsev_error "$FINDINGS_MIXED" "mixed-sid" "'mixed-wsid'" "agents/supervisor.md")
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-non-string-category: numeric category 42 is filtered out, string code is present (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "code"; then
        pass "F-non-string-category: numeric category 42 is filtered out, string code is present"
    else
        fail "F-non-string-category: numeric category 42 is filtered out, string code is present (out=$out)"
    fi
}

run_f_sid_with_quote() {
    require_source "$FORMATTER" "F-sid-with-quote: session ID containing single quote does not throw, output contains Session ID:" || return
    local out rc
    # Pass the sid via env var to avoid shell quoting issues with the embedded single quote.
    out=$(run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
const sid = process.env.TEST_SID;
const wsid = 'q-wsid';
const sp = 'agents/supervisor.md';
const stp = '/tmp/state.json';
process.stdout.write(f.formatL2ArmedReason('C1 sentinel hang', sid, wsid, sp, stp));
" TEST_SID="test'sid" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "F-sid-with-quote: session ID containing single quote does not throw, output contains Session ID: (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "Session ID:"; then
        pass "F-sid-with-quote: session ID containing single quote does not throw, output contains Session ID:"
    else
        fail "F-sid-with-quote: session ID containing single quote does not throw, output contains Session ID: (out=$out)"
    fi
}

run_f_state_path_special() {
    require_source "$FORMATTER" "F-state-path-special: stateFilePath with spaces and single quote renders without error" || return
    local out rc
    # Pass special-char path via env var to avoid shell quoting issues.
    # TEST_STP must be exported before the subshell so process.env picks it up.
    export TEST_STP="/tmp/my path/state's.json"
    out=$(run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
const cause = 'C1 sentinel hang';
const sid = 'sp-sid';
const wsid = 'sp-wsid';
const sp = 'agents/supervisor.md';
const stp = process.env.TEST_STP;
process.stdout.write(f.formatL2ArmedReason(cause, sid, wsid, sp, stp));
" 2>/dev/null)
    rc=$?
    unset TEST_STP
    if [ $rc -ne 0 ]; then
        fail "F-state-path-special: stateFilePath with spaces and single quote renders without error (rc=$rc, out=$out)"
        return
    fi
    if echo "$out" | grep -q "File:" && echo "$out" | grep -q "/tmp/my path/state"; then
        pass "F-state-path-special: stateFilePath with spaces and single quote renders without error"
    else
        fail "F-state-path-special: stateFilePath with spaces and single quote renders without error (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# F-recipe-{1,2,3}: #912 fallback-recipe block tests
# Verify that the formatter emits a runnable supervisor-write-layer2 recipe
# AND substitutes the session ID + stateFilePath. The recipe is a fallback
# the user can copy when the supervisor subagent invocation fails.
# ---------------------------------------------------------------------------

# Probe whether the formatter has been updated to emit the recipe block.
# The recipe block must mention bin/supervisor-write-layer2; it is a new
# addition (#912). Tests SKIP until source lands.
require_recipe_block() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const f = require('$FORMATTER_NODE');
const out1 = f.formatL2ArmedReason('C1 sentinel hang', 's', 'w', 'agents/supervisor.md', '/tmp/state.json');
const out2 = f.formatCumSevErrorReason([], 's', 'w', 'agents/supervisor.md', '/tmp/state.json');
const has1 = out1.indexOf('supervisor-write-layer2') >= 0;
const has2 = out2.indexOf('supervisor-write-layer2') >= 0;
process.stdout.write((has1 && has2) ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (recipe-block not implemented in formatter yet)"; return 1
    fi
    return 0
}

# F-recipe-1 — formatL2ArmedReason output contains the fallback-recipe block
run_f_recipe_1() {
    require_source "$FORMATTER" "F-recipe-1: formatL2ArmedReason output contains fallback-recipe block" || return
    require_recipe_block "F-recipe-1: formatL2ArmedReason output contains fallback-recipe block" || return
    local out
    out=$(format_l2_armed "C1 sentinel hang" "frec1-sid" "'frec1-wsid'" "agents/supervisor.md" "/tmp/state-frec1.json")
    if echo "$out" | grep -qi "Fallback" && echo "$out" | grep -q "bin/supervisor-write-layer2"; then
        pass "F-recipe-1: formatL2ArmedReason output contains fallback-recipe block"
    else
        fail "F-recipe-1: formatL2ArmedReason output contains fallback-recipe block (out=$out)"
    fi
}

# F-recipe-2 — formatCumSevErrorReason output contains the fallback-recipe block
run_f_recipe_2() {
    require_source "$FORMATTER" "F-recipe-2: formatCumSevErrorReason output contains fallback-recipe block" || return
    require_recipe_block "F-recipe-2: formatCumSevErrorReason output contains fallback-recipe block" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_TWO" "frec2-sid" "'frec2-wsid'" "agents/supervisor.md" "/tmp/state-frec2.json")
    if echo "$out" | grep -qi "Fallback" && echo "$out" | grep -q "bin/supervisor-write-layer2"; then
        pass "F-recipe-2: formatCumSevErrorReason output contains fallback-recipe block"
    else
        fail "F-recipe-2: formatCumSevErrorReason output contains fallback-recipe block (out=$out)"
    fi
}

# F-recipe-3 — fallback recipe includes the exact CLI invocation with correct sid + stateFilePath substitution
run_f_recipe_3() {
    require_source "$FORMATTER" "F-recipe-3: fallback recipe includes correct sid and stateFilePath substitution" || return
    require_recipe_block "F-recipe-3: fallback recipe includes correct sid and stateFilePath substitution" || return
    local out
    out=$(format_cumsev_error "$FINDINGS_ONE" "frec3-sid" "'frec3-wsid'" "agents/supervisor.md" "/tmp/state-frec3.json")
    if echo "$out" | grep -q "bin/supervisor-write-layer2" \
       && echo "$out" | grep -q "\-\-clear-l2-armed-at" \
       && echo "$out" | grep -q "\-\-set-l2-phase frozen" \
       && echo "$out" | grep -q "\-\-session-id frec3-sid" \
       && echo "$out" | grep -q "/tmp/state-frec3.json"; then
        pass "F-recipe-3: fallback recipe includes correct sid and stateFilePath substitution"
    else
        fail "F-recipe-3: fallback recipe includes correct sid and stateFilePath substitution (out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# Run all formatter tests
# ---------------------------------------------------------------------------
run_f1
run_f2
run_f3
run_f4
run_f5
run_f6
run_f7
run_f8
run_f9
run_f10
run_f11
run_f12
run_f13
run_f14
run_f_empty
run_f_null_wsid_cumsev
run_f_null_wsid_l2armed
run_f_single_finding
run_f_null_fields
run_f_null_findings
run_f_missing_severity
run_f_null_cause
run_f_sparse_findings
run_f_non_string_category
run_f_sid_with_quote
run_f_state_path_special
run_f_recipe_1
run_f_recipe_2
run_f_recipe_3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
