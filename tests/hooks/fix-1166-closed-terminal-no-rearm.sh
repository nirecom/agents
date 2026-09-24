#!/usr/bin/env bash
# Tests: hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js, hooks/supervisor-guard.js, hooks/stop-l2-findings-display.js
# Tags: supervisor, alert-phase, closed, paused, regression, #1166, scope:issue-specific
# L3 gap: hook-registration — real Stop event in a live claude -p session requires RUN_TL3=on.
# Validates: closed phase is terminal (no re-arm), eligible_phase bypass blocked, paused re-arms,
#   phase transition validation, writeAlertState closed clears eligible_phase.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
GUARD_HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
GUARD_HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-guard.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_writer() {
    local label="$1"
    if [ ! -f "$WRITER_MODULE" ]; then
        skip "$label (writer source not implemented yet)"; return 1
    fi
    return 0
}

# Seed alert state with an arbitrary phase / armed_at / retry_count.
# phase / armed_at are JS literals (use "null" or "'closed'"). retry_count numeric.
# Written directly (not via writeAlertState) so seeds can bypass transition validation.
seed_alert() {
    local tmp="$1" sid="$2" phase="$3" armed_at="$4" retry_count="$5" eligible="${6:-null}"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert = {
  alert_armed_at: $armed_at,
  last_run_at: null,
  cumulative_severity: null,
  findings: [],
  alert_phase: $phase,
  alert_cause: null,
  alert_retry_count: $retry_count,
  findings_surfaced_at: null,
  alert_eligible_phase: $eligible
};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# T1: closed + appendFinding -> phase stays closed, alert_armed_at null (no re-arm)
run_t1() {
    require_writer "T1: closed + appendFinding -> stays closed, not re-armed" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="t1-sid"
    seed_alert "$tmp" "$sid" "'closed'" "null" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'post-close finding', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'closed') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at != null) { console.error('alert_armed_at unexpectedly set: '+JSON.stringify(st.alert.alert_armed_at)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T1: closed + appendFinding -> stays closed, not re-armed"
    else
        fail "T1: closed + appendFinding -> stays closed, not re-armed (rc=$rc, out=$out)"
    fi
}

# T2: closed + alert_eligible_phase=post_final_report_window + final-report-env.json present + finding
#     -> NOT re-armed. Regression vector: the eligible_phase bypass path must not resurrect closed.
run_t2() {
    require_writer "T2: closed + eligible_phase bypass + marker -> NOT re-armed" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="t2-sid"
    seed_alert "$tmp" "$sid" "'closed'" "null" "0" "'post_final_report_window'"
    touch "$tmp/${sid}-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'closed') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at != null) { console.error('alert_armed_at unexpectedly set: '+JSON.stringify(st.alert.alert_armed_at)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T2: closed + eligible_phase bypass + marker -> NOT re-armed"
    else
        fail "T2: closed + eligible_phase bypass + marker -> NOT re-armed (rc=$rc, out=$out)"
    fi
}

# T3: paused + appendFinding -> re-arms to paused->pending, alert_retry_count reset to 0 (#967 preserved)
run_t3() {
    require_writer "T3: paused + appendFinding -> re-arms pending, retry reset 0" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="t3-sid"
    seed_alert "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at == null) { console.error('alert_armed_at not set'); process.exit(4); }
if (st.alert.alert_retry_count !== 0) { console.error('alert_retry_count not reset: '+JSON.stringify(st.alert.alert_retry_count)); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T3: paused + appendFinding -> re-arms pending, retry reset 0"
    else
        fail "T3: paused + appendFinding -> re-arms pending, retry reset 0 (rc=$rc, out=$out)"
    fi
}

# T4a: validateAlertPhaseTransition('closed','pending') -> rejected (permanent terminal)
run_t4a() {
    require_writer "T4a: validateAlertPhaseTransition closed->pending rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('closed', 'pending');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T4a: validateAlertPhaseTransition closed->pending rejected"
    else
        fail "T4a: validateAlertPhaseTransition closed->pending rejected (rc=$rc, out=$out)"
    fi
}

# T4b: validateAlertPhaseTransition('paused','pending') -> allowed (re-arm)
run_t4b() {
    require_writer "T4b: validateAlertPhaseTransition paused->pending allowed" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('paused', 'pending');
if (!r || r.ok !== true) { console.error('not allowed: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T4b: validateAlertPhaseTransition paused->pending allowed"
    else
        fail "T4b: validateAlertPhaseTransition paused->pending allowed (rc=$rc, out=$out)"
    fi
}

# T4c: validateAlertPhaseTransition('closed','done') -> rejected (permanent terminal blocks all transitions)
run_t4c() {
    require_writer "T4c: validateAlertPhaseTransition closed->done rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('closed', 'done');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T4c: validateAlertPhaseTransition closed->done rejected"
    else
        fail "T4c: validateAlertPhaseTransition closed->done rejected (rc=$rc, out=$out)"
    fi
}

# T6: writeAlertState alert_phase='closed' -> alert_eligible_phase cleared to null (#905 extension)
run_t6() {
    require_writer "T6: writeAlertState closed -> alert_eligible_phase cleared null" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="t6-sid"
    # Seed with eligible_phase set and phase=null so null->closed is a valid transition.
    seed_alert "$tmp" "$sid" "null" "null" "0" "'post_final_report_window'"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeAlertState('$sid', { alert_phase: 'closed' });
if (ok !== true) { console.error('writeAlertState returned: '+JSON.stringify(ok)); process.exit(2); }
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'closed') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_eligible_phase !== null) { console.error('alert_eligible_phase not cleared: '+JSON.stringify(st.alert.alert_eligible_phase)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T6: writeAlertState closed -> alert_eligible_phase cleared null"
    else
        fail "T6: writeAlertState closed -> alert_eligible_phase cleared null (rc=$rc, out=$out)"
    fi
}

run_t1
run_t2
run_t3
run_t4a
run_t4b
run_t4c
run_t6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
