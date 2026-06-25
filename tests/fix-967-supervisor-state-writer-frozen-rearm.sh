#!/usr/bin/env bash
# Tests: hooks/lib/supervisor-state-writer.js (ensureAlertScheduled frozen re-arm; validateL2PhaseTransition)
# Tags: supervisor, em-supervisor, layer2, writer, fix-967, scope:issue-specific
# RED for issue #967.
#
# Validates:
# - ensureAlertScheduled() must re-arm when phase is "frozen" (only "done"
#   short-circuits). Re-arm resets alert_phase=pending, sets alert_armed_at=<now>,
#   and resets alert_retry_count=0 so the freeze-on-retry counter starts fresh.
# - The final-report-env.json marker must be IGNORED when phase is "frozen"
#   (the marker only suppresses re-arm for non-frozen pre-final-report sessions).
# - validateL2PhaseTransition must allow frozen->pending (re-arm),
#   reject frozen->done and frozen->null, and treat frozen->frozen as a no-op.
#
# L3 gap (what this test does NOT catch):
# - hook registration — supervisor-state-writer.js is called by other hooks (trigger,
#   guard) which must be wired in settings.json; direct invocations here bypass that
# - real appendFinding call chain from supervisor-report CLI in a live session
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
#   fires at WORKFLOW_USER_VERIFIED preflight when hooks/*.js changes are staged

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

require_validateL2PhaseTransition_exported() {
    local label="$1"
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(typeof w.validateL2PhaseTransition === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (validateL2PhaseTransition not exported)"; return 1
    fi
    return 0
}

# Seed state with arbitrary layer2 fields. phase / cum_sev are JS literals
# (use "null" or "'pending'", etc.). retry_count is a numeric literal.
seed_state_layer2() {
    local tmp="$1" sid="$2" phase="$3" armed_at="$4" retry_count="$5"
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
  alert_retry_count: $retry_count
};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# R1: frozen phase + appendFinding -> ensureAlertScheduled re-arms (alert_phase becomes "pending")
run_r1() {
    require_writer "R1: frozen + appendFinding -> alert_phase becomes pending" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r1-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'new finding after freeze', reporter: 'test' });
if (r !== true) { console.error('appendFinding returned: '+r); process.exit(2); }
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R1: frozen + appendFinding -> alert_phase becomes pending"
    else
        fail "R1: frozen + appendFinding -> alert_phase becomes pending (rc=$rc, out=$out)"
    fi
}

# R2: frozen + appendFinding -> alert_armed_at is set to non-null
run_r2() {
    require_writer "R2: frozen + appendFinding -> alert_armed_at non-null" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r2-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_armed_at == null) { console.error('alert_armed_at='+JSON.stringify(st && st.alert.alert_armed_at)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R2: frozen + appendFinding -> alert_armed_at non-null"
    else
        fail "R2: frozen + appendFinding -> alert_armed_at non-null (rc=$rc, out=$out)"
    fi
}

# R3: frozen + appendFinding -> alert_retry_count reset to 0
run_r3() {
    require_writer "R3: frozen + appendFinding -> alert_retry_count reset to 0" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r3-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_retry_count !== 0) { console.error('alert_retry_count='+JSON.stringify(st && st.alert.alert_retry_count)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R3: frozen + appendFinding -> alert_retry_count reset to 0"
    else
        fail "R3: frozen + appendFinding -> alert_retry_count reset to 0 (rc=$rc, out=$out)"
    fi
}

# R4: done + appendFinding -> ensureAlertScheduled still short-circuits (done terminal)
run_r4() {
    require_writer "R4: done + appendFinding -> still short-circuits (done terminal)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r4-sid"
    seed_state_layer2 "$tmp" "$sid" "'done'" "null" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
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

# R5: frozen phase + final-report-env.json marker present -> marker IGNORED, frozen still re-arms
run_r5() {
    require_writer "R5: frozen + final-report-env.json marker -> marker ignored, still re-arms" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    # Marker file uses sessionId-final-report-env.json (see ensureAlertScheduled line ~83).
    touch "$tmp/${sid}-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
const st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_armed_at == null) { console.error('alert_armed_at not set'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R5: frozen + final-report-env.json marker -> marker ignored, still re-arms"
    else
        fail "R5: frozen + final-report-env.json marker -> marker ignored, still re-arms (rc=$rc, out=$out)"
    fi
}

# R5b: null phase + final-report-env.json marker present -> STILL SUPPRESSES re-arm (regression)
# Validates that the frozen-bypass of the marker does not accidentally remove the marker check
# for non-frozen phases.
run_r5b() {
    require_writer "R5b: null phase + marker -> suppresses re-arm (regression)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5b-sid"
    seed_state_layer2 "$tmp" "$sid" "null" "null" "0"
    touch "$tmp/${sid}-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
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

# R5c: re-frozen cycle — frozen->re-arm->pending->incrementRetry×threshold->frozen->re-arm
# Validates that re-arm resets retry_count=0 so the freeze cycle can repeat correctly.
run_r5c() {
    require_writer "R5c: re-frozen cycle (frozen->rearm->re-frozen->rearm)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r5c-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const w = require('$WRITER_NODE');
// Re-arm from frozen
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 'd', reporter: 't' });
let st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('post-rearm alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(3); }
if (st.alert.alert_retry_count !== 0) { console.error('retry_count not reset: '+st.alert.alert_retry_count); process.exit(4); }
// Exhaust retries to re-freeze (ALERT_RETRY_THRESHOLD=2)
const threshold = s.ALERT_RETRY_THRESHOLD;
for (let i = 0; i < threshold; i++) { w.incrementAlertRetryCount('$sid'); }
st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'frozen') { console.error('post-exhaust alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(5); }
// Re-arm again from re-frozen
w.appendFinding('$sid', { categories: ['workflow'], severity: 'error', detail: 're-arm-2', reporter: 't' });
st = w.readState('$sid');
if (!st || st.alert.alert_phase !== 'pending') { console.error('second rearm alert_phase='+JSON.stringify(st && st.alert.alert_phase)); process.exit(6); }
if (st.alert.alert_retry_count !== 0) { console.error('second cycle retry_count: '+st.alert.alert_retry_count); process.exit(7); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R5c: re-frozen cycle (frozen->rearm->re-frozen->rearm)"
    else
        fail "R5c: re-frozen cycle (frozen->rearm->re-frozen->rearm) (rc=$rc, out=$out)"
    fi
}

# R6a: validateL2PhaseTransition frozen -> pending => allowed
run_r6a() {
    require_writer "R6a: validateL2PhaseTransition frozen->pending allowed" || return
    require_validateL2PhaseTransition_exported "R6a: validateL2PhaseTransition frozen->pending allowed" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateL2PhaseTransition('frozen', 'pending');
if (!r || r.ok !== true) { console.error('not allowed: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6a: validateL2PhaseTransition frozen->pending allowed"
    else
        fail "R6a: validateL2PhaseTransition frozen->pending allowed (rc=$rc, out=$out)"
    fi
}

# R6b: validateL2PhaseTransition frozen -> done => REJECTED
run_r6b() {
    require_writer "R6b: validateL2PhaseTransition frozen->done rejected" || return
    require_validateL2PhaseTransition_exported "R6b: validateL2PhaseTransition frozen->done rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateL2PhaseTransition('frozen', 'done');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6b: validateL2PhaseTransition frozen->done rejected"
    else
        fail "R6b: validateL2PhaseTransition frozen->done rejected (rc=$rc, out=$out)"
    fi
}

# R6c: validateL2PhaseTransition frozen -> frozen => allowed (idempotent)
run_r6c() {
    require_writer "R6c: validateL2PhaseTransition frozen->frozen idempotent" || return
    require_validateL2PhaseTransition_exported "R6c: validateL2PhaseTransition frozen->frozen idempotent" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateL2PhaseTransition('frozen', 'frozen');
if (!r || r.ok !== true) { console.error('not allowed: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6c: validateL2PhaseTransition frozen->frozen idempotent"
    else
        fail "R6c: validateL2PhaseTransition frozen->frozen idempotent (rc=$rc, out=$out)"
    fi
}

# R6d: validateL2PhaseTransition frozen -> null => REJECTED
run_r6d() {
    require_writer "R6d: validateL2PhaseTransition frozen->null rejected" || return
    require_validateL2PhaseTransition_exported "R6d: validateL2PhaseTransition frozen->null rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateL2PhaseTransition('frozen', null);
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6d: validateL2PhaseTransition frozen->null rejected"
    else
        fail "R6d: validateL2PhaseTransition frozen->null rejected (rc=$rc, out=$out)"
    fi
}

# R6e: validateL2PhaseTransition done -> pending => REJECTED (pre-existing behavior, regression)
run_r6e() {
    require_writer "R6e: validateL2PhaseTransition done->pending rejected (regression)" || return
    require_validateL2PhaseTransition_exported "R6e: validateL2PhaseTransition done->pending rejected" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.validateL2PhaseTransition('done', 'pending');
if (!r || r.ok !== false) { console.error('not rejected: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "R6e: validateL2PhaseTransition done->pending rejected (regression)"
    else
        fail "R6e: validateL2PhaseTransition done->pending rejected (regression) (rc=$rc, out=$out)"
    fi
}

# R7: pending phase + appendFinding -> ensureAlertScheduled skips (already armed)
run_r7() {
    require_writer "R7: pending + appendFinding -> skips re-arm (already armed)" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r7-sid"
    seed_state_layer2 "$tmp" "$sid" "'pending'" "'2026-06-06T11:00:00.000Z'" "0"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
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
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
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

# R9: writeAlertState({alert_phase:'pending', alert_armed_at:<now>, alert_retry_count:0}) on frozen state -> returns true
# Tests that writeAlertState uses validateL2PhaseTransition internally and allows frozen->pending.
run_r9() {
    require_writer "R9: writeAlertState frozen->pending -> returns true" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="r9-sid"
    seed_state_layer2 "$tmp" "$sid" "'frozen'" "null" "2"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
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
        pass "R9: writeAlertState frozen->pending -> returns true"
    else
        fail "R9: writeAlertState frozen->pending -> returns true (rc=$rc, out=$out)"
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
