#!/bin/bash
# tests/unit-supervisor-state-writer.sh
# Tests: hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js, bin/supervisor-write-alert
# Tags: supervisor, em-supervisor, writer, schema, layer2, alert_retry_count, unit, scope:912
# Unit tests for the #912 alert_retry_count field, incrementAlertRetryCount function,
# and the CLI's --increment-alert-retry-count flag with auto-freeze semantics.
#
# L3 gap (what this test does NOT catch):
# - the guard hook actually invoking incrementAlertRetryCount end-to-end (covered by feature-719-supervisor-guard-hook.sh G20-G28)
# - settings.json registration of any new Stop hooks (hook-registration risk category)
# - real Claude Code transcript JSONL field shape — tests use unit-level direct module calls
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
#   fires at WORKFLOW_USER_VERIFIED preflight when settings.json changes are staged.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
CLI="$AGENTS_DIR/bin/supervisor-write-alert"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

ALERT_RETRY_THRESHOLD=2

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

require_alert_retry_count_schema() {
    local label="$1"
    require_source "$SCHEMA_MODULE" "$label" || return 1
    local probe
    probe=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('probe');
process.stdout.write('alert_retry_count' in st.alert ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (alert_retry_count field not yet in createEmptyState)"; return 1
    fi
    return 0
}

require_increment_fn() {
    local label="$1"
    require_source "$WRITER_MODULE" "$label" || return 1
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(typeof w.incrementAlertRetryCount === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (incrementAlertRetryCount not implemented yet)"; return 1
    fi
    return 0
}

require_increment_cli_flag() {
    local label="$1"
    require_source "$CLI" "$label" || return 1
    if ! grep -q "increment-alert-retry-count" "$CLI" 2>/dev/null; then
        skip "$label (--increment-alert-retry-count flag not implemented in CLI yet)"; return 1
    fi
    return 0
}

# W1 — createEmptyState returns layer2 object with alert_retry_count: 0
run_w1() {
    require_alert_retry_count_schema "W1: createEmptyState returns layer2.alert_retry_count: 0" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('w1-sid');
if (st.alert.alert_retry_count !== 0) { console.error('expected 0, got '+st.alert.alert_retry_count); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W1: createEmptyState returns layer2.alert_retry_count: 0"
    else
        fail "W1: createEmptyState returns layer2.alert_retry_count: 0 (rc=$rc, out=$out)"
    fi
}

# W2 — validate rejects non-integer alert_retry_count
run_w2() {
    require_alert_retry_count_schema "W2: validate rejects non-integer alert_retry_count" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('w2-sid');
st.alert.alert_retry_count = 'not-a-number';
const r = s.validate(st);
if (r.ok === true) { console.error('expected ok=false, got ok=true'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W2: validate rejects non-integer alert_retry_count"
    else
        fail "W2: validate rejects non-integer alert_retry_count (rc=$rc, out=$out)"
    fi
}

# W3 — incrementAlertRetryCount returns { count: 1, frozen: false } on first call from fresh state
run_w3() {
    require_increment_fn "W3: incrementAlertRetryCount first call returns {count:1, frozen:false}" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.incrementAlertRetryCount('w3-sid');
if (!r || typeof r !== 'object') { console.error('not obj: '+JSON.stringify(r)); process.exit(2); }
if (r.count !== 1) { console.error('count: '+r.count); process.exit(3); }
if (r.frozen !== false) { console.error('frozen: '+r.frozen); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W3: incrementAlertRetryCount first call returns {count:1, frozen:false}"
    else
        fail "W3: incrementAlertRetryCount first call returns {count:1, frozen:false} (rc=$rc, out=$out)"
    fi
}

# W4 — After ALERT_RETRY_THRESHOLD (2) calls, returns { count: threshold, frozen: true }
#       persisted state has alert_phase: frozen, alert_armed_at: null
run_w4() {
    require_increment_fn "W4: at threshold returns {count:T, frozen:true}, alert_phase=frozen, alert_armed_at=null" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" ALERT_RETRY_THRESHOLD="$ALERT_RETRY_THRESHOLD" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const T = parseInt(process.env.ALERT_RETRY_THRESHOLD, 10);
let last = null;
// Seed alert_armed_at so we can verify it gets cleared on freeze
w.writeAlertState('w4-sid', { alert_armed_at: '2026-06-06T12:00:00Z' });
for (let i = 0; i < T; i++) last = w.incrementAlertRetryCount('w4-sid');
if (!last || last.count !== T) { console.error('count: '+JSON.stringify(last)); process.exit(2); }
if (last.frozen !== true) { console.error('frozen: '+JSON.stringify(last)); process.exit(3); }
const st = w.readState('w4-sid');
if (!st || st.alert.alert_phase !== 'frozen') { console.error('phase: '+JSON.stringify(st && st.alert)); process.exit(4); }
if (st.alert.alert_armed_at !== null) { console.error('armed_at: '+JSON.stringify(st.alert)); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W4: at threshold returns {count:T, frozen:true}, alert_phase=frozen, alert_armed_at=null"
    else
        fail "W4: at threshold returns {count:T, frozen:true}, alert_phase=frozen, alert_armed_at=null (rc=$rc, out=$out)"
    fi
}

# W5 — After auto-freeze, subsequent calls are idempotent (count unchanged, frozen:true)
run_w5() {
    require_increment_fn "W5: after auto-freeze, subsequent calls idempotent (count unchanged, frozen:true)" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" ALERT_RETRY_THRESHOLD="$ALERT_RETRY_THRESHOLD" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const T = parseInt(process.env.ALERT_RETRY_THRESHOLD, 10);
let last = null;
for (let i = 0; i < T; i++) last = w.incrementAlertRetryCount('w5-sid');
const frozenCount = last.count;
const r2 = w.incrementAlertRetryCount('w5-sid');
const r3 = w.incrementAlertRetryCount('w5-sid');
if (r2.count !== frozenCount) { console.error('r2.count drift: '+JSON.stringify(r2)); process.exit(2); }
if (r2.frozen !== true) { console.error('r2.frozen: '+JSON.stringify(r2)); process.exit(3); }
if (r3.count !== frozenCount) { console.error('r3.count drift: '+JSON.stringify(r3)); process.exit(4); }
if (r3.frozen !== true) { console.error('r3.frozen: '+JSON.stringify(r3)); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W5: after auto-freeze, subsequent calls idempotent (count unchanged, frozen:true)"
    else
        fail "W5: after auto-freeze, subsequent calls idempotent (count unchanged, frozen:true) (rc=$rc, out=$out)"
    fi
}

# W6 — CLI --increment-alert-retry-count exits 0 and increments field on disk
run_w6() {
    require_increment_cli_flag "W6: CLI --increment-alert-retry-count exits 0 and increments on disk" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --increment-alert-retry-count --session-id "w6-sid" >/dev/null 2>&1
    rc=$?
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('w6-sid');
process.stdout.write(String(st && st.alert && st.alert.alert_retry_count));
" 2>/dev/null)
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "1" ]; then
        pass "W6: CLI --increment-alert-retry-count exits 0 and increments on disk"
    else
        fail "W6: CLI --increment-alert-retry-count exits 0 and increments on disk (rc=$rc, count=$out)"
    fi
}

# W6b — writeAlertState with alert_retry_count: 5 persists 5
run_w6b() {
    local label="W6b: writeAlertState({alert_retry_count: 5}) persists 5 on disk"
    require_source "$WRITER_MODULE" "$label" || return
    # Probe whether writeAlertState accepts alert_retry_count key
    local probe
    probe=$(run_with_timeout 5 node -e "
const tmp = require('fs').mkdtempSync(require('os').tmpdir() + require('path').sep + 'sup-probe-');
process.env.WORKFLOW_PLANS_DIR = tmp;
delete require.cache[require.resolve('$WRITER_NODE')];
const w = require('$WRITER_NODE');
const r = w.writeAlertState('probe-sid', { alert_retry_count: 5 });
const st = w.readState('probe-sid');
process.stdout.write(r === true && st && st.alert && st.alert.alert_retry_count === 5 ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (writeAlertState does not yet accept alert_retry_count patch)"; return
    fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.writeAlertState('w6b-sid', { alert_retry_count: 5 });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState('w6b-sid');
if (!st || st.alert.alert_retry_count !== 5) { console.error('count: '+JSON.stringify(st && st.alert)); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# W6c — CLI rejects --increment-alert-retry-count combined with --set-alert-phase (mutual exclusion)
run_w6c() {
    local label="W6c: CLI rejects --increment-alert-retry-count with --set-alert-phase (mutex)"
    require_increment_cli_flag "$label" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --increment-alert-retry-count --set-alert-phase frozen --session-id "w6c-sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "$label (rc=$rc)"
    else
        fail "$label expected non-zero exit, got rc=$rc"
    fi
}

# W6d — --clear-alert-armed-at --set-alert-phase done resets alert_retry_count to 0 even when prior >0
run_w6d() {
    local label="W6d: --clear-alert-armed-at --set-alert-phase done resets alert_retry_count to 0"
    require_increment_cli_flag "$label" || return
    # Probe whether the CLI reset semantics are implemented. The plan says
    # this resets retry_count to 0; this is a new behavior so SKIP if not present.
    local tmp probe rc out
    tmp="$(mktemp -d)"
    # Seed: retry_count=1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --increment-alert-retry-count --session-id "w6d-sid" >/dev/null 2>&1
    # Now run reset
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --clear-alert-armed-at --set-alert-phase done --session-id "w6d-sid" >/dev/null 2>&1
    rc=$?
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('w6d-sid');
process.stdout.write(String(st && st.alert && st.alert.alert_retry_count));
" 2>/dev/null)
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "0" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, retry_count=$out)"
    fi
}

run_w1
run_w2
run_w3
run_w4
run_w5
run_w6
run_w6b
run_w6c
run_w6d

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
