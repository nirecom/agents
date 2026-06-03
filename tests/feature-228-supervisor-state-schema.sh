#!/bin/bash
# tests/feature-228-supervisor-state-schema.sh
# Tests: hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, schema, unit
# Tests for issue #228 — supervisor-state schema module unit tests.
#
# Verifies the JSON Schema + validator behavior for supervisor-state.json:
# createEmptyState, validate, validateFinding, LAYER1_CHECKS.
#
# RED: SKIPs all cases while source module is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# --- S1 ----------------------------------------------------------------------
run_s1() {
    require_source "$SCHEMA_MODULE" "S1: createEmptyState returns required keys" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s1');
const req = ['version','session_id','created_at','last_updated','layer1','layer2','layer3'];
for (const k of req) {
  if (!(k in st)) { console.error('MISSING:'+k); process.exit(2); }
}
if (!Array.isArray(st.layer1.findings)) { console.error('layer1.findings not array'); process.exit(3); }
if (typeof st.layer2 !== 'object' || st.layer2 === null) { console.error('layer2 not object'); process.exit(4); }
if (typeof st.layer3 !== 'object' || st.layer3 === null) { console.error('layer3 not object'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S1: createEmptyState returns required keys"
    else
        fail "S1: createEmptyState returns required keys (rc=$rc, out=$out)"
    fi
}

# --- S2 ----------------------------------------------------------------------
run_s2() {
    require_source "$SCHEMA_MODULE" "S2: validate(state) ok for valid state + finding" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s2');
st.layer1.findings.push({ check: 'plan_artifact', status: 'warn', detail: 'd' });
const r = s.validate(st);
if (r.ok !== true) { console.error('not ok: '+JSON.stringify(r)); process.exit(2); }
if (!Array.isArray(r.errors) || r.errors.length !== 0) { console.error('errors not empty'); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S2: validate(state) ok for valid state + finding"
    else
        fail "S2: validate(state) ok for valid state + finding (rc=$rc, out=$out)"
    fi
}

# --- S3 ----------------------------------------------------------------------
run_s3() {
    require_source "$SCHEMA_MODULE" "S3: validate fails when session_id missing" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s3');
delete st.session_id;
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S3: validate fails when session_id missing"
    else
        fail "S3: validate fails when session_id missing (rc=$rc, out=$out)"
    fi
}

# --- S4 ----------------------------------------------------------------------
run_s4() {
    require_source "$SCHEMA_MODULE" "S4: validate detects invalid status value" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s4');
st.layer1.findings.push({ check: 'plan_artifact', status: 'invalid', detail: 'd' });
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
if (!Array.isArray(r.errors) || r.errors.length === 0) { console.error('errors empty'); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S4: validate detects invalid status value"
    else
        fail "S4: validate detects invalid status value (rc=$rc, out=$out)"
    fi
}

# --- S5 ----------------------------------------------------------------------
run_s5() {
    require_source "$SCHEMA_MODULE" "S5: validate detects check enum violation" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s5');
st.layer1.findings.push({ check: 'not_a_real_check', status: 'warn', detail: 'd' });
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S5: validate detects check enum violation"
    else
        fail "S5: validate detects check enum violation (rc=$rc, out=$out)"
    fi
}

# --- S6 ----------------------------------------------------------------------
run_s6() {
    require_source "$SCHEMA_MODULE" "S6: validateFinding ok for valid finding" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const r = s.validateFinding({ check: 'plan_artifact', status: 'warn', detail: 'test' });
if (r.ok !== true) { console.error('not ok: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S6: validateFinding ok for valid finding"
    else
        fail "S6: validateFinding ok for valid finding (rc=$rc, out=$out)"
    fi
}

# --- S7 ----------------------------------------------------------------------
run_s7() {
    require_source "$SCHEMA_MODULE" "S7: layer2/layer3 additionalProperties allowed" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-s7');
st.layer2 = { customField: 42 };
st.layer3 = { foo: 'bar' };
const r = s.validate(st);
if (r.ok !== true) { console.error('expected ok=true: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S7: layer2/layer3 additionalProperties allowed"
    else
        fail "S7: layer2/layer3 additionalProperties allowed (rc=$rc, out=$out)"
    fi
}

# --- S8 ----------------------------------------------------------------------
run_s8() {
    require_source "$SCHEMA_MODULE" "S8: LAYER1_CHECKS has exactly 4 elements" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const c = s.LAYER1_CHECKS;
if (!Array.isArray(c)) { console.error('not array'); process.exit(2); }
if (c.length !== 4) { console.error('expected 4, got '+c.length); process.exit(3); }
const expected = ['plan_artifact','scope_keyword','non_goal_keyword','sentinel'];
for (const e of expected) {
  if (!c.includes(e)) { console.error('missing '+e); process.exit(4); }
}
if (c.includes('schema_validation')) { console.error('schema_validation should not be present'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S8: LAYER1_CHECKS has exactly 4 elements"
    else
        fail "S8: LAYER1_CHECKS has exactly 4 elements (rc=$rc, out=$out)"
    fi
}

run_s1
run_s2
run_s3
run_s4
run_s5
run_s6
run_s7
run_s8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
