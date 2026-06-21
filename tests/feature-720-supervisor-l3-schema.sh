#!/bin/bash
# tests/feature-720-supervisor-l3-schema.sh
# Tests: hooks/lib/supervisor-state-schema.js (L3 additions)
# Tags: supervisor, em-supervisor, schema, layer3, unit, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   Pure schema unit test. It does NOT verify that the live supervisor-guard
#   reads/writes these L3 fields in a real claude -p Stop event sequence.
# RED for issue #720.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
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

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# L3 additions are detected by presence of L3_PHASE_VALUES export.
l3_present() {
    [ -f "$SCHEMA" ] || return 1
    grep -q "L3_PHASE_VALUES" "$SCHEMA" 2>/dev/null
}

require_l3() {
    local label="$1"
    if ! l3_present; then skip "$label (L3 fields not yet added to schema)"; return 1; fi
    return 0
}

run_s1() {
    require_source "$SCHEMA" "S1: createEmptyState includes layer3 L3 fields" || return
    require_l3 "S1: createEmptyState includes layer3 L3 fields" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('s1');
const need = ['l3_phase','l3_verdict','l3_last_run_at','l3_armed_at','l3_cause','l3_retry_count'];
for (const k of need) {
  if (!(k in st.layer3)) { console.error('missing '+k); process.exit(2); }
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S1: createEmptyState includes layer3 L3 fields"
    else
        fail "S1: createEmptyState includes layer3 L3 fields (rc=$rc, out=$out)"
    fi
}

run_s2() {
    require_source "$SCHEMA" "S2: validate accepts l3_phase=pending, l3_verdict=null" || return
    require_l3 "S2: validate accepts l3_phase=pending, l3_verdict=null" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('s2');
st.layer3.l3_phase = 'pending';
st.layer3.l3_verdict = null;
const r = s.validate(st);
if (r.ok !== true) { console.error('not ok: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S2: validate accepts l3_phase=pending, l3_verdict=null"
    else
        fail "S2: validate accepts l3_phase=pending, l3_verdict=null (rc=$rc, out=$out)"
    fi
}

run_s3() {
    require_source "$SCHEMA" "S3: validate rejects bad l3_phase enum" || return
    require_l3 "S3: validate rejects bad l3_phase enum" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('s3');
st.layer3.l3_phase = 'bad-value';
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S3: validate rejects bad l3_phase enum"
    else
        fail "S3: validate rejects bad l3_phase enum (rc=$rc, out=$out)"
    fi
}

run_s4() {
    require_source "$SCHEMA" "S4: validate rejects bad l3_verdict enum" || return
    require_l3 "S4: validate rejects bad l3_verdict enum" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('s4');
st.layer3.l3_verdict = 'bad-value';
const r = s.validate(st);
if (r.ok !== false) { console.error('expected ok=false'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S4: validate rejects bad l3_verdict enum"
    else
        fail "S4: validate rejects bad l3_verdict enum (rc=$rc, out=$out)"
    fi
}

run_s5() {
    require_source "$SCHEMA" "S5: validate accepts legacy layer3:{} (backward compat)" || return
    require_l3 "S5: validate accepts legacy layer3:{} (backward compat)" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('s5');
st.layer3 = {};
const r = s.validate(st);
if (r.ok !== true) { console.error('expected ok=true (legacy): '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S5: validate accepts legacy layer3:{} (backward compat)"
    else
        fail "S5: validate accepts legacy layer3:{} (backward compat) (rc=$rc, out=$out)"
    fi
}

run_s6() {
    require_source "$SCHEMA" "S6: L3_CUMULATIVE_SEVERITY_THRESHOLD exported = 'error'" || return
    require_l3 "S6: L3_CUMULATIVE_SEVERITY_THRESHOLD exported = 'error'" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
if (s.L3_CUMULATIVE_SEVERITY_THRESHOLD !== 'error') { console.error('got '+s.L3_CUMULATIVE_SEVERITY_THRESHOLD); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S6: L3_CUMULATIVE_SEVERITY_THRESHOLD exported = 'error'"
    else
        fail "S6: L3_CUMULATIVE_SEVERITY_THRESHOLD exported = 'error' (rc=$rc, out=$out)"
    fi
}

run_s7() {
    require_source "$SCHEMA" "S7: L3_PHASE_VALUES contains expected enum" || return
    require_l3 "S7: L3_PHASE_VALUES contains expected enum" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const v = s.L3_PHASE_VALUES;
if (!Array.isArray(v)) { console.error('not array'); process.exit(2); }
const need = [null, 'pending', 'in_progress', 'done', 'frozen'];
for (const e of need) {
  if (!v.includes(e)) { console.error('missing '+JSON.stringify(e)); process.exit(3); }
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S7: L3_PHASE_VALUES contains expected enum"
    else
        fail "S7: L3_PHASE_VALUES contains expected enum (rc=$rc, out=$out)"
    fi
}

run_s8() {
    require_source "$SCHEMA" "S8: L3_VERDICT_VALUES contains CONTINUE/WARN/BLOCK" || return
    require_l3 "S8: L3_VERDICT_VALUES contains CONTINUE/WARN/BLOCK" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const v = s.L3_VERDICT_VALUES;
if (!Array.isArray(v)) { console.error('not array'); process.exit(2); }
for (const e of ['CONTINUE','WARN','BLOCK']) {
  if (!v.includes(e)) { console.error('missing '+e); process.exit(3); }
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "S8: L3_VERDICT_VALUES contains CONTINUE/WARN/BLOCK"
    else
        fail "S8: L3_VERDICT_VALUES contains CONTINUE/WARN/BLOCK (rc=$rc, out=$out)"
    fi
}

run_s1; run_s2; run_s3; run_s4; run_s5; run_s6; run_s7; run_s8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
