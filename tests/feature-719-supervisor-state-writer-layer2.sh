#!/bin/bash
# tests/feature-719-supervisor-state-writer-layer2.sh
# Tests: hooks/lib/supervisor-state-writer.js (writeLayer2State)
# Tags: supervisor, em-supervisor, writer, layer2, unit
# RED for issue #719.

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

require_writer_layer2() {
    local label="$1"
    if [ ! -f "$WRITER_MODULE" ]; then
        skip "$label (writer source not implemented yet)"; return 1
    fi
    local probe
    probe=$(run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
process.stdout.write(typeof w.writeLayer2State === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label (writeLayer2State not implemented yet)"; return 1
    fi
    return 0
}

run_w1() {
    require_writer_layer2 "W1: writeLayer2State sets next_check_at, preserves layer1" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w1-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('$sid', { categories: ['workflow'], severity: 'warning', detail: 'seed', reporter: 't' });
const r = w.writeLayer2State('$sid', { next_check_at: '2026-06-06T12:00:00Z' });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState('$sid');
if (!st || st.layer2.next_check_at !== '2026-06-06T12:00:00Z') { console.error('next_check_at not set'); process.exit(3); }
if (!Array.isArray(st.layer1.findings) || st.layer1.findings.length !== 1) { console.error('layer1 not preserved'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W1: writeLayer2State sets next_check_at, preserves layer1"
    else
        fail "W1: writeLayer2State sets next_check_at, preserves layer1 (rc=$rc, out=$out)"
    fi
}

run_w2() {
    require_writer_layer2 "W2: writeLayer2State sets last_run_at + cumulative_severity" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w2-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.writeLayer2State('$sid', { last_run_at: '2026-06-06T11:00:00Z', cumulative_severity: 'warning' });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState('$sid');
if (st.layer2.last_run_at !== '2026-06-06T11:00:00Z') { console.error('last_run_at'); process.exit(3); }
if (st.layer2.cumulative_severity !== 'warning') { console.error('cumulative_severity'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W2: writeLayer2State sets last_run_at + cumulative_severity"
    else
        fail "W2: writeLayer2State sets last_run_at + cumulative_severity (rc=$rc, out=$out)"
    fi
}

run_w3() {
    require_writer_layer2 "W3: writeLayer2State appends to layer2.findings" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w3-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const r = w.writeLayer2State('$sid', { findings: [{ categories: ['intent'], severity: 'error', detail: 'd', reporter: 'supervisor' }] });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState('$sid');
if (!Array.isArray(st.layer2.findings) || st.layer2.findings.length !== 1) { console.error('findings len'); process.exit(3); }
const f = st.layer2.findings[0];
if (!Array.isArray(f.categories) || f.categories[0] !== 'intent') { console.error('cat'); process.exit(4); }
if (f.severity !== 'error') { console.error('sev'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W3: writeLayer2State appends to layer2.findings"
    else
        fail "W3: writeLayer2State appends to layer2.findings (rc=$rc, out=$out)"
    fi
}

run_w4() {
    require_writer_layer2 "W4: writeLayer2State rejects invalid cumulative_severity" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w4-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeLayer2State('$sid', { cumulative_severity: 'warning' });
const before = JSON.stringify(w.readState('$sid'));
const r = w.writeLayer2State('$sid', { cumulative_severity: 'critical' });
if (r !== false) { console.error('expected false, got '+r); process.exit(2); }
const after = JSON.stringify(w.readState('$sid'));
if (before !== after) { console.error('state mutated despite invalid'); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W4: writeLayer2State rejects invalid cumulative_severity"
    else
        fail "W4: writeLayer2State rejects invalid cumulative_severity (rc=$rc, out=$out)"
    fi
}

run_w5() {
    require_writer_layer2 "W5: post-write state validates ok=true" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w5-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
w.writeLayer2State('$sid', { next_check_at: '2026-06-06T12:00:00Z', cumulative_severity: 'warning' });
const st = w.readState('$sid');
const r = s.validate(st);
if (r.ok !== true) { console.error('not ok: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W5: post-write state validates ok=true"
    else
        fail "W5: post-write state validates ok=true (rc=$rc, out=$out)"
    fi
}

run_w6() {
    require_writer_layer2 "W6: writeLayer2State on missing file creates it" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="w6-sid"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const p = w.getStatePath('$sid');
if (fs.existsSync(p)) { console.error('state file exists before test'); process.exit(2); }
const r = w.writeLayer2State('$sid', { next_check_at: '2026-06-06T12:00:00Z' });
if (r !== true) { console.error('write returned: '+r); process.exit(3); }
if (!fs.existsSync(p)) { console.error('state file missing after write'); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "W6: writeLayer2State on missing file creates it"
    else
        fail "W6: writeLayer2State on missing file creates it (rc=$rc, out=$out)"
    fi
}

run_w1
run_w2
run_w3
run_w4
run_w5
run_w6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
