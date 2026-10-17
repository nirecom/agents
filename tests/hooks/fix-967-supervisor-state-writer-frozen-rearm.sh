#!/usr/bin/env bash
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, layer2, writer, fix-967, paused, scope:issue-specific
# #967/#1166, flipped by #2698: a new finding never re-arms a "paused" alert (phase stays paused,
# armed_at stays null, retry unchanged) but the finding is still recorded; only an explicit
# writeAlertState resume leaves paused. done/closed short-circuit; the final-report-env.json
# marker still suppresses a null-phase arm. validateAlertPhaseTransition: paused->pending ok;
# paused->done, done->pending no.
# L3 gap: hook registration and the live supervisor-report call chain
# (mitigated by bin/check-verification-gate.sh hook-registration).

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

WRITER_MODULE="$SCRIPT_CHECKOUT_ROOT/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-schema.js"

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

require_validateAlertPhaseTransition_exported() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(typeof w.validateAlertPhaseTransition === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (validateAlertPhaseTransition not exported)"; return 1
    fi
    return 0
}

# Seed state with arbitrary layer2 fields. phase / cum_sev are JS literals
# (use "null" or "'pending'", etc.). retry_count is a numeric literal.
seed_state_layer2() {
    local tmp="$1" sid="$2" phase="$3" armed_at="$4" retry_count="$5"
    WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
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
  alert_retry_count: $retry_count
};
fs.writeFileSync(w.getStatePath('$sid', { forWrite: true }), JSON.stringify(st));
" >/dev/null 2>&1
}

seed_marker() {
    local tmp="$1" sid="$2"
    WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const cd = require('$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io/control-dir.js');
require('fs').writeFileSync(cd.controlPath('$sid', 'final-report-env.json', { forWrite: true }), '');
" >/dev/null 2>&1
}

# R1 (#2698): paused phase + appendFinding -> alert_phase stays "paused", finding still recorded
run_r1() {
    require_writer "R1: paused + appendFinding -> alert_phase stays paused, finding recorded" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r1-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'new finding after pause', reporter: 'test' });
if (r !== true) { console.error('appendFinding returned: '+r); process.exit(2); }
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'paused') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (!st.layer1.findings.some((f) => f.detail === 'new finding after pause')) { console.error('finding not recorded'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R1: paused + appendFinding -> alert_phase stays paused, finding recorded"
    else
        fail "R1: paused + appendFinding -> alert_phase stays paused, finding recorded (rc=$rc, out=$out)"
    fi
}

# R2 (#2698): paused + appendFinding -> alert_armed_at stays null
run_r2() {
    require_writer "R2: paused + appendFinding -> alert_armed_at stays null" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r2-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_armed_at !== null) { console.error('alert_armed_at='+JSON.stringify(st && st.alert.alert_armed_at)); process.exit(3); }
if (!st.layer1.findings.some((f) => f.detail === 'd')) { console.error('finding not recorded'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R2: paused + appendFinding -> alert_armed_at stays null"
    else
        fail "R2: paused + appendFinding -> alert_armed_at stays null (rc=$rc, out=$out)"
    fi
}

# R3 (#2698): paused + appendFinding -> alert_retry_count unchanged (no reset)
run_r3() {
    require_writer "R3: paused + appendFinding -> alert_retry_count unchanged" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r3-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_retry_count !== 2) { console.error('alert_retry_count='+JSON.stringify(st && st.alert.alert_retry_count)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R3: paused + appendFinding -> alert_retry_count unchanged"
    else
        fail "R3: paused + appendFinding -> alert_retry_count unchanged (rc=$rc, out=$out)"
    fi
}

# R4: done + appendFinding -> ensureAlertScheduled still short-circuits (done terminal)
run_r4() {
    require_writer "R4: done + appendFinding -> still short-circuits (done terminal)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r4-sid"
    seed_state_layer2 "$tmp" "$sid" "'done'" "null" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'done') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at != null) { console.error('alert_armed_at unexpectedly set: '+JSON.stringify(st.alert.alert_armed_at)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R4: done + appendFinding -> still short-circuits (done terminal)"
    else
        fail "R4: done + appendFinding -> still short-circuits (done terminal) (rc=$rc, out=$out)"
    fi
}

# R5 (#2698): paused phase + final-report-env.json marker present -> stays paused, finding recorded
run_r5() {
    require_writer "R5: paused + final-report-env.json marker -> stays paused, finding recorded" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    seed_marker "$tmp" "$sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'paused') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at !== null) { console.error('alert_armed_at unexpectedly set: '+JSON.stringify(st.alert.alert_armed_at)); process.exit(4); }
if (!st.layer1.findings.some((f) => f.detail === 'd')) { console.error('finding not recorded'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R5: paused + final-report-env.json marker -> stays paused, finding recorded"
    else
        fail "R5: paused + final-report-env.json marker -> stays paused, finding recorded (rc=$rc, out=$out)"
    fi
}

# R5b: null phase + final-report-env.json marker present -> STILL SUPPRESSES re-arm (regression)
# Validates that the paused-bypass of the marker does not accidentally remove the marker check
# for non-paused phases.
run_r5b() {
    require_writer "R5b: null phase + marker -> suppresses re-arm (regression)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5b-sid"
    seed_state_layer2 "$tmp" "$sid" "null" "null" "0"
    seed_marker "$tmp" "$sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_armed_at != null) { console.error('alert_armed_at unexpectedly set: '+JSON.stringify(st && st.alert.alert_armed_at)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R5b: null phase + marker -> suppresses re-arm (regression)"
    else
        fail "R5b: null phase + marker -> suppresses re-arm (regression) (rc=$rc, out=$out)"
    fi
}

# R5c (#2698): pause cycle — a finding keeps paused; only an explicit writeAlertState resume
# (pending, fresh armed_at, retry 0) leaves it; retries re-freeze; the next finding keeps paused.
run_r5c() {
    require_writer "R5c: pause cycle (finding keeps paused -> explicit resume -> re-paused -> finding keeps paused)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5c-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
let st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'paused') { console.error('post-finding alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
// Explicit resume
const ok = w.writeAlertState('$sid', { alert_phase: 'pending', alert_armed_at: new Date().toISOString(), alert_retry_count: 0 });
st = w.readState('$sid');
if (ok !== true || st.alert.alert_phase !== 'pending') { console.error('resume failed: '+JSON.stringify(st && st.alert)); process.exit(4); }
// Exhaust retries to re-pause (ALERT_RETRY_THRESHOLD=2)
const threshold = s.ALERT_RETRY_THRESHOLD;
for (let i = 0; i < threshold; i++) { w.incrementAlertRetryCount('$sid'); }
st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'paused') { console.error('post-exhaust alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(5); }
const retryBefore = st.alert.alert_retry_count;
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'after-re-pause', reporter: 't' });
st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'paused') { console.error('second finding alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(6); }
if (st.alert.alert_retry_count !== retryBefore) { console.error('retry_count changed: '+st.alert.alert_retry_count); process.exit(7); }
if (!st.layer1.findings.some((f) => f.detail === 'after-re-pause')) { console.error('finding not recorded'); process.exit(8); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R5c: pause cycle (finding keeps paused -> explicit resume -> re-paused -> finding keeps paused)"
    else
        fail "R5c: pause cycle (finding keeps paused -> explicit resume -> re-paused -> finding keeps paused) (rc=$rc, out=$out)"
    fi
}

# R6a: validateAlertPhaseTransition paused -> pending => allowed
run_r6a() {
    require_writer "R6a: validateAlertPhaseTransition paused->pending allowed" || return
    require_validateAlertPhaseTransition_exported "R6a: validateAlertPhaseTransition paused->pending allowed" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('paused', 'pending');
if (!r || r.ok !== true) { console.error('not allowed: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6a: validateAlertPhaseTransition paused->pending allowed"
    else
        fail "R6a: validateAlertPhaseTransition paused->pending allowed (rc=$rc, out=$out)"
    fi
}

# R6b: validateAlertPhaseTransition paused -> done => REJECTED
run_r6b() {
    require_writer "R6b: validateAlertPhaseTransition paused->done rejected" || return
    require_validateAlertPhaseTransition_exported "R6b: validateAlertPhaseTransition paused->done rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('paused', 'done');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6b: validateAlertPhaseTransition paused->done rejected"
    else
        fail "R6b: validateAlertPhaseTransition paused->done rejected (rc=$rc, out=$out)"
    fi
}

# R6c: validateAlertPhaseTransition paused -> paused => allowed (idempotent)
run_r6c() {
    require_writer "R6c: validateAlertPhaseTransition paused->paused idempotent" || return
    require_validateAlertPhaseTransition_exported "R6c: validateAlertPhaseTransition paused->paused idempotent" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('paused', 'paused');
if (!r || r.ok !== true) { console.error('not allowed: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6c: validateAlertPhaseTransition paused->paused idempotent"
    else
        fail "R6c: validateAlertPhaseTransition paused->paused idempotent (rc=$rc, out=$out)"
    fi
}

# R6d: validateAlertPhaseTransition closed -> null => REJECTED (closed is permanent terminal)
run_r6d() {
    require_writer "R6d: validateAlertPhaseTransition closed->null rejected" || return
    require_validateAlertPhaseTransition_exported "R6d: validateAlertPhaseTransition closed->null rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('closed', null);
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6d: validateAlertPhaseTransition closed->null rejected"
    else
        fail "R6d: validateAlertPhaseTransition closed->null rejected (rc=$rc, out=$out)"
    fi
}

# R6e: validateAlertPhaseTransition done -> pending => REJECTED (pre-existing behavior, regression)
run_r6e() {
    require_writer "R6e: validateAlertPhaseTransition done->pending rejected (regression)" || return
    require_validateAlertPhaseTransition_exported "R6e: validateAlertPhaseTransition done->pending rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateAlertPhaseTransition('done', 'pending');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6e: validateAlertPhaseTransition done->pending rejected (regression)"
    else
        fail "R6e: validateAlertPhaseTransition done->pending rejected (regression) (rc=$rc, out=$out)"
    fi
}

# R7: pending phase + appendFinding -> ensureAlertScheduled skips (already armed)
run_r7() {
    require_writer "R7: pending + appendFinding -> skips re-arm (already armed)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r7-sid"
    seed_state_layer2 "$tmp" "$sid" "'pending'" "'2026-06-06T11:00:00.000Z'" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_armed_at !== '2026-06-06T11:00:00.000Z') { console.error('alert_armed_at changed: '+JSON.stringify(st && st.alert.alert_armed_at)); process.exit(3); }
if (st.alert.alert_phase !== 'pending') { console.error('alert_phase changed: '+JSON.stringify(st.alert.alert_phase)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R7: pending + appendFinding -> skips re-arm (already armed)"
    else
        fail "R7: pending + appendFinding -> skips re-arm (already armed) (rc=$rc, out=$out)"
    fi
}

# R8: null phase + appendFinding -> ensureAlertScheduled arms normally
run_r8() {
    require_writer "R8: null phase + appendFinding -> arms normally" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r8-sid"
    seed_state_layer2 "$tmp" "$sid" "null" "null" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at == null) { console.error('alert_armed_at not set'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R8: null phase + appendFinding -> arms normally"
    else
        fail "R8: null phase + appendFinding -> arms normally (rc=$rc, out=$out)"
    fi
}

# R9: writeAlertState({alert_phase:'pending', alert_armed_at:<now>, alert_retry_count:0}) on paused state -> returns true
# Tests that writeAlertState uses validateAlertPhaseTransition internally and allows paused->pending.
run_r9() {
    require_writer "R9: writeAlertState paused->pending -> returns true" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r9-sid"
    seed_state_layer2 "$tmp" "$sid" "'paused'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp/workflow" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const now = new Date().toISOString();
const result = w.writeAlertState('$sid', { alert_phase: 'pending', alert_armed_at: now, alert_retry_count: 0 });
if (result !== true) { console.error('writeAlertState returned: '+JSON.stringify(result)); process.exit(3); }
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R9: writeAlertState paused->pending -> returns true"
    else
        fail "R9: writeAlertState paused->pending -> returns true (rc=$rc, out=$out)"
    fi
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r5b
run_r5c
run_r6a
run_r6b
run_r6c
run_r6d
run_r6e
run_r7
run_r8
run_r9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
