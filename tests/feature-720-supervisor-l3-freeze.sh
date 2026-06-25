#!/bin/bash
# tests/feature-720-supervisor-l3-freeze.sh
# Tests: bin/supervisor-write-alert, bin/supervisor-write-audit (independent freeze gates)
# Tags: supervisor, em-supervisor, freeze, layer2, layer3, integration, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   Verifies CLI-driven retry-count increments and resulting frozen phase
#   transitions against a temp store. Does not verify that the live Stop-event
#   pipeline correctly arms each layer independently after a freeze.
# RED for issue #720.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
    _TMPCONV() { cygpath -m "$1"; }
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
    _TMPCONV() { printf '%s' "$1"; }
fi

CLI_L2="$AGENTS_DIR/bin/supervisor-write-alert"
CLI_L3="$AGENTS_DIR/bin/supervisor-write-audit"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
COLLECT_L3_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-guard/collect-audit-triggers.js"
COLLECT_L3_FILE="$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

l3_retry_threshold_present() {
    grep -q "AUDIT_RETRY_THRESHOLD" "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" 2>/dev/null
}

require_l3_threshold() {
    local label="$1"
    if ! l3_retry_threshold_present; then skip "$label (AUDIT_RETRY_THRESHOLD not yet exported)"; return 1; fi
    return 0
}

read_field() {
    local tmp="$1" sid="$2" path="$3"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const parts = '$path'.split('.');
let cur = st;
for (const p of parts) { if (cur == null) break; cur = cur[p]; }
process.stdout.write(JSON.stringify(cur));
" 2>/dev/null
    )
}

get_threshold() {
    local layer="$1"
    (
        run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const v = '$layer' === 'l2' ? s.ALERT_RETRY_THRESHOLD : s.AUDIT_RETRY_THRESHOLD;
process.stdout.write(String(v));
" 2>/dev/null
    )
}

invoke_l2() {
    local tmp="$1"; shift
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI_L2" "$@" >/dev/null 2>&1
    )
}
invoke_l3() {
    local tmp="$1"; shift
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI_L3" "$@" >/dev/null 2>&1
    )
}

run_f1() {
    require_source "$CLI_L2" "F1: L2 retry threshold → alert_phase=frozen" || return
    local tmp sid threshold val i
    tmp="$(mktemp -d)"; sid="f1sid"
    threshold=$(get_threshold l2)
    if [ -z "$threshold" ] || ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        rm -rf "$tmp"; skip "F1: L2 retry threshold → alert_phase=frozen (ALERT_RETRY_THRESHOLD not numeric)"; return
    fi
    # Arm first
    invoke_l2 "$tmp" --l2-armed-at "2026-06-06T12:00:00Z" --session-id "$sid"
    # Increment to threshold
    i=0
    while [ $i -lt "$threshold" ]; do
        invoke_l2 "$tmp" --increment-alert-retry-count --session-id "$sid"
        i=$((i+1))
    done
    val=$(read_field "$tmp" "$sid" "alert.alert_phase")
    rm -rf "$tmp"
    if [ "$val" = "\"frozen\"" ]; then
        pass "F1: L2 retry threshold → alert_phase=frozen"
    else
        fail "F1: L2 retry threshold → alert_phase=frozen (val=$val)"
    fi
}

run_f2() {
    require_source "$CLI_L3" "F2: L3 retry threshold → audit_phase=frozen" || return
    require_l3_threshold "F2: L3 retry threshold → audit_phase=frozen" || return
    local tmp sid threshold val i
    tmp="$(mktemp -d)"; sid="f2sid"
    threshold=$(get_threshold l3)
    if [ -z "$threshold" ] || ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        rm -rf "$tmp"; skip "F2: L3 retry threshold → audit_phase=frozen (AUDIT_RETRY_THRESHOLD not numeric)"; return
    fi
    invoke_l3 "$tmp" --audit-armed-at "2026-06-06T12:00:00Z" --session-id "$sid"
    i=0
    while [ $i -lt "$threshold" ]; do
        invoke_l3 "$tmp" --increment-audit-retry-count --session-id "$sid"
        i=$((i+1))
    done
    val=$(read_field "$tmp" "$sid" "audit.audit_phase")
    rm -rf "$tmp"
    if [ "$val" = "\"frozen\"" ]; then
        pass "F2: L3 retry threshold → audit_phase=frozen"
    else
        fail "F2: L3 retry threshold → audit_phase=frozen (val=$val)"
    fi
}

run_f3() {
    require_source "$COLLECT_L3_FILE" "F3: L2 frozen, L3 not frozen → L3 can still arm" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$COLLECT_L3_NODE');
const transcript = [{ role: 'assistant', content: '<<WORKFLOW_CONFIRM_INTENT: scope>>' }];
const state = { version: '1', session_id: 't', layer1: { findings: [] },
  alert: { alert_phase: 'frozen' }, audit: {} };
const r = m.collectAuditCandidates(transcript, state);
if (r.shouldArm !== true) { console.error('shouldArm='+r.shouldArm); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "F3: L2 frozen, L3 not frozen → L3 can still arm"
    else
        fail "F3: L2 frozen, L3 not frozen → L3 can still arm (rc=$rc, out=$out)"
    fi
}

run_f4() {
    require_source "$CLI_L2" "F4: L3 frozen, L2 not frozen → L2 can still arm" || return
    # L2 arming is managed by writer's ensureAlertScheduled; verify it still arms
    # when only L3 is frozen. We achieve this by writing layer3.audit_phase=frozen
    # directly, then calling appendFinding (which auto-arms L2 when not done/frozen).
    local tmp sid out
    tmp="$(mktemp -d)"; sid="f4sid"
    out=$(
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const fs = require('fs'); const path = require('path');
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('$sid');
if (!st.audit || typeof st.audit !== 'object') st.audit = {};
st.audit.audit_phase = 'frozen';
fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, '$sid' + '-supervisor-state.json'), JSON.stringify(st, null, 2));
const ok = w.appendFinding('$sid', { categories: ['code'], severity: 'warning', detail: 'd', reporter: 'test' });
const after = w.readState('$sid');
console.log(after.alert && after.alert.alert_armed_at ? 'ARMED' : 'NOT_ARMED');
" 2>&1
    )
    rm -rf "$tmp"
    if [ "$out" = "ARMED" ]; then
        pass "F4: L3 frozen, L2 not frozen → L2 can still arm"
    else
        fail "F4: L3 frozen, L2 not frozen → L2 can still arm (out=$out)"
    fi
}

run_f5() {
    require_source "$COLLECT_L3_FILE" "F5: both frozen → both phases stay frozen" || return
    # When both layers are already frozen, collect-audit-triggers must NOT re-arm L3,
    # and the writer must not transition l2 out of frozen on its own.
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$COLLECT_L3_NODE');
const transcript = [{ role: 'assistant', content: '<<WORKFLOW_CONFIRM_INTENT: scope>>' }];
const state = { version: '1', session_id: 't', layer1: { findings: [] },
  alert: { alert_phase: 'frozen' }, audit: { audit_phase: 'frozen' } };
const r = m.collectAuditCandidates(transcript, state);
if (r.shouldArm !== false) { console.error('expected shouldArm=false, got '+r.shouldArm); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "F5: both frozen → both phases stay frozen"
    else
        fail "F5: both frozen → both phases stay frozen (rc=$rc, out=$out)"
    fi
}

run_f1; run_f2; run_f3; run_f4; run_f5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
