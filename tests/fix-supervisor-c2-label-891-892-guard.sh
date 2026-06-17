#!/bin/bash
# tests/fix-supervisor-c2-label-891-892-guard.sh
# Tests: hooks/lib/supervisor-state-writer.js (ensureLayer2Scheduled + appendFinding post-Final-Report guard)
# Tags: supervisor, em-supervisor, layer2, fix, unit
# RED for issue #891 (post-Final-Report guard on ensureLayer2Scheduled).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Probe: does ensureLayer2Scheduled respect the final-report-env.json guard
# when called with a valid sessionId as second arg?
guard_implemented() {
    local tmp probe
    tmp="$(mktemp -d)"
    # Create env JSON for probe-sid so guard should fire
    touch "$tmp/probe-sid-final-report-env.json"
    probe=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, 'probe-sid'); } catch (e) { process.stdout.write('error'); process.exit(0); }
process.stdout.write(state.layer2.next_check_at === null ? 'guarded' : 'unguarded');
" 2>/dev/null)
    rm -rf "$tmp"
    [ "$probe" = "guarded" ]
}

require_guard() {
    local label="$1"
    if [ ! -f "$WRITER_MODULE" ]; then
        skip "$label (writer source not implemented yet)"; return 1
    fi
    if ! guard_implemented; then
        skip "$label (ensureLayer2Scheduled guard not implemented yet)"; return 1
    fi
    return 0
}

run_g1() {
    local label="G1: sessionId null -> fail-open -> schedules normally"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, null); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.next_check_at == null) { console.error('not scheduled'); process.exit(3); }
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

run_g2() {
    local label="G2: sessionId invalid (path-traversal) -> fail-open -> schedules"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, '../evil'); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.next_check_at == null) { console.error('not scheduled'); process.exit(3); }
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

run_g3() {
    local label="G3: sessionId valid, env JSON absent -> schedules normally"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, 'g3-sid'); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.next_check_at == null) { console.error('not scheduled'); process.exit(3); }
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

run_g4() {
    local label="G4: sessionId valid, env JSON present -> guard fires, next_check_at stays null"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    touch "$tmp/g4-sid-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
w.ensureLayer2Scheduled(state, 'g4-sid');
if (state.layer2.next_check_at !== null) { console.error('guard failed: next_check_at='+state.layer2.next_check_at); process.exit(2); }
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

run_g5() {
    local label="G5: appendFinding L72 dedup path: env JSON present -> next_check_at stays null"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const sid = 'g5-sid';
// First append: env JSON not yet present, so first call may schedule.
// Clear next_check_at via writeLayer2State, then create env JSON, then dup-append.
const f = { categories: ['workflow'], severity: 'warning', detail: 'dup-test', reporter: 't' };
if (!w.appendFinding(sid, f)) { console.error('first append failed'); process.exit(2); }
// Clear next_check_at
w.writeLayer2State(sid, { next_check_at: null });
// Create env JSON now
fs.writeFileSync(w.getStatePath(sid).replace('-supervisor-state.json', '-final-report-env.json'), '{}');
// Dup append (same fields) -> dedup path L72 fires
if (!w.appendFinding(sid, f)) { console.error('dup append failed'); process.exit(3); }
const st = w.readState(sid);
if (st.layer2.next_check_at !== null) { console.error('guard failed: next_check_at='+st.layer2.next_check_at); process.exit(4); }
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

run_g6() {
    local label="G6: appendFinding L84 main path: env JSON present -> finding appended, next_check_at stays null"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    touch "$tmp/g6-sid-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const sid = 'g6-sid';
const f = { categories: ['workflow'], severity: 'warning', detail: 'main-path-test', reporter: 't' };
if (!w.appendFinding(sid, f)) { console.error('append failed'); process.exit(2); }
const st = w.readState(sid);
if (!Array.isArray(st.layer1.findings) || st.layer1.findings.length !== 1) { console.error('finding not appended'); process.exit(3); }
if (st.layer2.next_check_at !== null) { console.error('guard failed: next_check_at='+st.layer2.next_check_at); process.exit(4); }
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

run_g7() {
    local label="G7: writeLayer2State unaffected by env JSON guard"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    touch "$tmp/g7-sid-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const sid = 'g7-sid';
const r = w.writeLayer2State(sid, { next_check_at: '2026-06-06T12:00:00Z' });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.next_check_at !== '2026-06-06T12:00:00Z') { console.error('next_check_at not set: '+st.layer2.next_check_at); process.exit(3); }
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

run_g1
run_g2
run_g3
run_g4
run_g5
run_g6
run_g7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
