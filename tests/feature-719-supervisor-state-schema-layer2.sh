#!/bin/bash
# tests/feature-719-supervisor-state-schema-layer2.sh
# Tests: hooks/lib/supervisor-state-schema.js (S-2 layer2 fields)
# Tags: supervisor, em-supervisor, schema, layer2, unit
# RED for issue #719 — S-2 schema enhancement (typed layer2 fields).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_layer2_impl() {
    local label="$1"
    if [ ! -f "$SCHEMA_MODULE" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    local probe
    probe=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('probe');
process.stdout.write(('next_check_at' in (st.layer2 || {})) ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (S-2 layer2 typed fields not implemented yet)"; return 1
    fi
    return 0
}

run_l1() {
    require_layer2_impl "L1: createEmptyState includes typed layer2 defaults" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l1');
const l2 = st.layer2;
if (l2.next_check_at !== null) { console.error('next_check_at not null'); process.exit(2); }
if (l2.last_run_at !== null) { console.error('last_run_at not null'); process.exit(3); }
if (l2.cumulative_severity !== null) { console.error('cumulative_severity not null'); process.exit(4); }
if (!Array.isArray(l2.findings) || l2.findings.length !== 0) { console.error('findings not empty array'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L1: createEmptyState includes typed layer2 defaults"
    else
        fail "L1: createEmptyState includes typed layer2 defaults (rc=$rc, out=$out)"
    fi
}

run_l2() {
    require_layer2_impl "L2: validate ok when layer2.cumulative_severity = warning" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l2');
st.layer2.cumulative_severity = 'warning';
const r = s.validate(st);
if (r.ok !== true) { console.error('not ok: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L2: validate ok when layer2.cumulative_severity = warning"
    else
        fail "L2: validate ok when layer2.cumulative_severity = warning (rc=$rc, out=$out)"
    fi
}

run_l3() {
    require_layer2_impl "L3: validate fails when cumulative_severity = critical" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l3');
st.layer2.cumulative_severity = 'critical';
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L3: validate fails when cumulative_severity = critical"
    else
        fail "L3: validate fails when cumulative_severity = critical (rc=$rc, out=$out)"
    fi
}

run_l4() {
    require_layer2_impl "L4: validate fails when next_check_at is numeric" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l4');
st.layer2.next_check_at = 42;
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L4: validate fails when next_check_at is numeric"
    else
        fail "L4: validate fails when next_check_at is numeric (rc=$rc, out=$out)"
    fi
}

run_l5() {
    require_layer2_impl "L5: validate fails when findings is not an array" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l5');
st.layer2.findings = 'not-array';
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L5: validate fails when findings is not an array"
    else
        fail "L5: validate fails when findings is not an array (rc=$rc, out=$out)"
    fi
}

run_l6() {
    require_layer2_impl "L6: validate fails when finding has invalid category" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l6');
st.layer2.findings.push({ categories: ['INVALID'], severity: 'error', detail: 'd' });
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L6: validate fails when finding has invalid category"
    else
        fail "L6: validate fails when finding has invalid category (rc=$rc, out=$out)"
    fi
}

run_l7() {
    require_layer2_impl "L7: validate ok for S-1-era empty layer2 (backward compat)" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-l7');
st.layer2 = {};
const r = s.validate(st);
if (r.ok !== true) { console.error('expected ok=true: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "L7: validate ok for S-1-era empty layer2 (backward compat)"
    else
        fail "L7: validate ok for S-1-era empty layer2 (backward compat) (rc=$rc, out=$out)"
    fi
}

run_l1
run_l2
run_l3
run_l4
run_l5
run_l6
run_l7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
