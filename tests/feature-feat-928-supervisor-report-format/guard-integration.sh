#!/bin/bash
# tests/feature-feat-928-supervisor-report-format/guard-integration.sh
# Guard integration tests (G/GN/B tests) — supervisor-guard.js end-to-end.
# Runnable standalone: bash tests/feature-feat-928-supervisor-report-format/guard-integration.sh

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ---------------------------------------------------------------------------
# G* regression tests
# ---------------------------------------------------------------------------

run_g2_regression() {
    require_source "$HOOK" "G2-regression: systemMessage present in branch(2) output" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g2r-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g2r-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "systemMessage"; then
        pass "G2-regression: systemMessage present in branch(2) output"
    else
        fail "G2-regression: systemMessage present in branch(2) output (rc=$rc, out=$out)"
    fi
}

run_g19_regression() {
    require_source "$HOOK" "G19-regression: branch(2) reason contains last finding detail" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g19r-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"workflow\"],\"severity\":\"error\",\"detail\":\"first-finding\",\"timestamp\":\"2026-06-06T11:00:00.000Z\"},{\"categories\":[\"workflow\"],\"severity\":\"error\",\"detail\":\"last-finding\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g19r-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "last-finding"; then
        pass "G19-regression: branch(2) reason contains last finding detail"
    else
        fail "G19-regression: branch(2) reason contains last finding detail (rc=$rc, out=$out)"
    fi
}

run_g20_regression() {
    require_source "$HOOK" "G20-regression: branch(2) output contains Session ID: <sid>" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g20r-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g20r-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Session ID: g20r-sid"; then
        pass "G20-regression: branch(2) output contains Session ID: <sid>"
    else
        fail "G20-regression: branch(2) output contains Session ID: <sid> (rc=$rc, out=$out)"
    fi
}

run_g21_regression() {
    require_source "$HOOK" "G21-regression: branch(2) output contains Workflow session ID: <wsid>" || return
    local tmp out rc TODAY wsid
    tmp="$(mktemp -d)"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g21rwsid"
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    seed_state "$tmp" "g21r-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"g21r-sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G21-regression: branch(2) output contains Workflow session ID: <wsid>"
    else
        fail "G21-regression: branch(2) output contains Workflow session ID: <wsid> (rc=$rc, out=$out)"
    fi
}

run_g22_regression() {
    require_source "$HOOK" "G22-regression: branch(2) output contains both session ID tokens" || return
    local tmp out rc TODAY wsid
    tmp="$(mktemp -d)"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g22rwsid"
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    seed_state "$tmp" "g22r-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"g22r-sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Session ID: g22r-sid" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G22-regression: branch(2) output contains both session ID tokens"
    else
        fail "G22-regression: branch(2) output contains both session ID tokens (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# GN* new integration tests
# ---------------------------------------------------------------------------

run_gn1() {
    require_source "$HOOK" "GN1: branch(2) guard output contains Categories: field" || return
    require_source "$FORMATTER" "GN1: branch(2) guard output contains Categories: field" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "gn1-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"workflow\",\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"gn1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Categories:"; then
        pass "GN1: branch(2) guard output contains Categories: field"
    else
        fail "GN1: branch(2) guard output contains Categories: field (rc=$rc, out=$out)"
    fi
}

run_gn2() {
    require_source "$HOOK" "GN2: branch(3) guard output uses human-readable text as primary instruction" || return
    require_source "$FORMATTER" "GN2: branch(3) guard output uses human-readable text as primary instruction" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "gn2-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"gn2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # Primary instruction must be human-readable (To resume / Clear:) — not start with raw "node -e \"require("
    if [ $rc -ne 2 ]; then
        fail "GN2: branch(3) guard output uses human-readable text as primary instruction (rc=$rc, out=$out)"
        return
    fi
    if ! ( echo "$out" | grep -qE "To resume|Clear:" ); then
        fail "GN2: branch(3) guard output uses human-readable text as primary instruction (missing readable phrase, out=$out)"
        return
    fi
    pass "GN2: branch(3) guard output uses human-readable text as primary instruction"
}

# ---------------------------------------------------------------------------
# B* boundary tests
# ---------------------------------------------------------------------------

run_b4_warning() {
    require_source "$HOOK" "B4-warning: advisory warning state exits 0 and contains additionalContext" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "b4w-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'warning', findings: [{\"categories\":[\"code\"],\"severity\":\"warning\",\"detail\":\"advisory\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"b4w-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q "additionalContext"; then
        pass "B4-warning: advisory warning state exits 0 and contains additionalContext"
    else
        fail "B4-warning: advisory warning state exits 0 and contains additionalContext (rc=$rc, out=$out)"
    fi
}

run_b4_notice() {
    require_source "$HOOK" "B4-notice: advisory notice state exits 0 and contains additionalContext" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "b4n-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'notice', findings: [{\"categories\":[\"code\"],\"severity\":\"notice\",\"detail\":\"advisory\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"b4n-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q "additionalContext"; then
        pass "B4-notice: advisory notice state exits 0 and contains additionalContext"
    else
        fail "B4-notice: advisory notice state exits 0 and contains additionalContext (rc=$rc, out=$out)"
    fi
}

run_b5_null_state() {
    require_source "$HOOK" "B5-null-state: all-null state exits 0 and does not block" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "b5-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"b5-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"decision":"block"'; then
        pass "B5-null-state: all-null state exits 0 and does not block"
    else
        fail "B5-null-state: all-null state exits 0 and does not block (rc=$rc, out=$out)"
    fi
}

run_b1_stop_hook_active() {
    require_source "$HOOK" "B1-stop-hook-active: stop_hook_active=true exits 0 without reading state" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # No state file seeded — guard must exit before touching state
    out=$(echo '{"stop_hook_active":true,"session_id":"b1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q "decision"; then
        pass "B1-stop-hook-active: stop_hook_active=true exits 0 without reading state"
    else
        fail "B1-stop-hook-active: stop_hook_active=true exits 0 without reading state (rc=$rc, out=$out)"
    fi
}

run_b_l2phase_done() {
    require_source "$HOOK" "B-l2phase-done: l2ArmedAt set but alert_phase=done exits 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "l2done-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', alert_phase: 'done', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"l2done-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"decision":"block"'; then
        pass "B-l2phase-done: l2ArmedAt set but alert_phase=done exits 0 (no block)"
    else
        fail "B-l2phase-done: l2ArmedAt set but alert_phase=done exits 0 (rc=$rc, out=$out)"
    fi
}

run_b_l2phase_frozen() {
    require_source "$HOOK" "B-l2phase-frozen: l2ArmedAt set but alert_phase=frozen exits 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "l2frozen-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', alert_phase: 'frozen', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"l2frozen-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"decision":"block"'; then
        pass "B-l2phase-frozen: l2ArmedAt set but alert_phase=frozen exits 0 (no block)"
    else
        fail "B-l2phase-frozen: l2ArmedAt set but alert_phase=frozen exits 0 (rc=$rc, out=$out)"
    fi
}

run_b_workflow_off() {
    require_source "$HOOK" "B-workflow-off: WORKFLOW_OFF session marker exits 0 even with error state" || return
    local tmp woff_dir out rc
    tmp="$(mktemp -d)"
    woff_dir="$(mktemp -d)"
    # Seed supervisor state that would normally trigger a block
    seed_state "$tmp" "woff-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"d\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    # Create the workflow-off marker: <CLAUDE_WORKFLOW_DIR>/<sid>.workflow-off
    touch "$woff_dir/woff-sid.workflow-off"
    out=$(echo '{"stop_hook_active":false,"session_id":"woff-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" CLAUDE_WORKFLOW_DIR="$woff_dir" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$woff_dir"
    if [ $rc -eq 0 ]; then
        pass "B-workflow-off: WORKFLOW_OFF session marker exits 0 even with error state"
    else
        fail "B-workflow-off: WORKFLOW_OFF session marker exits 0 even with error state (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# Run all guard integration tests
# ---------------------------------------------------------------------------
run_g2_regression
run_g19_regression
run_g20_regression
run_g21_regression
run_g22_regression
run_gn1
run_gn2
run_b4_warning
run_b4_notice
run_b5_null_state
run_b1_stop_hook_active
run_b_l2phase_done
run_b_l2phase_frozen
run_b_workflow_off

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
