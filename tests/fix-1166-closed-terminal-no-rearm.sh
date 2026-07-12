#!/usr/bin/env bash
# Tests: hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js, hooks/supervisor-guard.js, hooks/stop-l2-findings-display.js
# Tags: supervisor, alert-phase, closed, paused, frozen, regression, #1166, scope:issue-specific
# L3 gap: hook-registration — whether the hook actually fires on Stop events in a real
#          claude -p session requires RUN_E2E=on; skipped here (L2 unit-level).
#
# RED for issue #1166 (pre-implementation).
#
# Validates the closed-terminal + frozen->paused rename semantics:
# - alert_phase="closed" is a permanent terminal phase: appendFinding must NOT re-arm.
# - The alert_eligible_phase=post_final_report_window bypass must NOT resurrect a closed phase.
# - alert_phase="paused" (renamed from "frozen") still re-arms on new findings (preserves #967).
# - validateAlertPhaseTransition: closed->pending rejected; paused->pending allowed.
# - migrateLegacyState up-casts legacy alert_phase="frozen" to "paused".
# - writeAlertState with alert_phase="closed" clears alert_eligible_phase to null (#905 extension).
# - supervisor-guard treats legacy alert_phase="frozen" as terminal (backward-compat alias).

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

# T5: migrateLegacyState({alert:{alert_phase:'frozen'}}) -> alert_phase becomes 'paused'
run_t5() {
    require_writer "T5: migrateLegacyState frozen -> paused" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
// readStateOrInit invokes migrateLegacyState; assert the up-cast via a seeded on-disk frozen state.
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const os = require('os');
const path = require('path');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mig-'));
process.env.WORKFLOW_PLANS_DIR = tmp;
delete require.cache[require.resolve('$WRITER_NODE')];
const w2 = require('$WRITER_NODE');
const st = s.createEmptyState('mig-sid');
st.alert.alert_phase = 'frozen';
fs.writeFileSync(w2.getStatePath('mig-sid'), JSON.stringify(st));
const migrated = w2.readStateOrInit('mig-sid');
if (!migrated || !migrated.alert || migrated.alert.alert_phase !== 'paused') {
  console.error('alert_phase after migrate='+JSON.stringify(migrated && migrated.alert && migrated.alert.alert_phase));
  process.exit(3);
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "T5: migrateLegacyState frozen -> paused"
    else
        fail "T5: migrateLegacyState frozen -> paused (rc=$rc, out=$out)"
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

# T7: supervisor-guard with legacy readState() returning alert_phase='frozen' -> treated as terminal.
# Guard branch (3): armed alert with a terminal phase must NOT block (exit 0, no block JSON).
run_t7() {
    require_writer "T7: guard treats legacy frozen as terminal (no block)" || return
    if [ ! -f "$GUARD_HOOK" ]; then skip "T7: guard treats legacy frozen as terminal (guard not present)"; return; fi
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="t7-sid"
    # Seed an armed alert with the legacy frozen phase. If frozen were NOT terminal,
    # the armed alert_armed_at would fire guard branch (3) and emit a block.
    seed_alert "$tmp" "$sid" "'frozen'" "'2026-06-06T11:00:00.000Z'" "0"
    out=$(printf '{"session_id":"%s","transcript_path":"/nonexistent","stop_hook_active":false}' "$sid" \
        | WORKFLOW_PLANS_DIR="$tmp" AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout 10 node "$GUARD_HOOK_NODE" 2>&1)
    rc=$?
    rm -rf "$tmp"
    # Terminal frozen: guard must not block. Block would be exit 2 + a decision:"block" line.
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q '"decision":"block"'; then
        pass "T7: guard treats legacy frozen as terminal (no block)"
    else
        fail "T7: guard treats legacy frozen as terminal (no block) (rc=$rc, out=$out)"
    fi
}

run_t1
run_t2
run_t3
run_t4a
run_t4b
run_t4c
run_t5
run_t6
run_t7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
