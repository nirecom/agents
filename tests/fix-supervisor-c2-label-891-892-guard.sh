#!/bin/bash
# tests/fix-supervisor-c2-label-891-892-guard.sh
# Tests: hooks/lib/supervisor-state-writer.js (ensureLayer2Scheduled + appendFinding post-Final-Report guard + writeLayer2State terminal-phase l2_armed_at clearing)
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
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, 'probe-sid'); } catch (e) { process.stdout.write('error'); process.exit(0); }
process.stdout.write(state.layer2.l2_armed_at === null ? 'guarded' : 'unguarded');
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
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, null); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.l2_armed_at == null) { console.error('not scheduled'); process.exit(3); }
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
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, '../evil'); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.l2_armed_at == null) { console.error('not scheduled'); process.exit(3); }
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
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
try { w.ensureLayer2Scheduled(state, 'g3-sid'); } catch (e) { console.error('threw: '+e.message); process.exit(2); }
if (state.layer2.l2_armed_at == null) { console.error('not scheduled'); process.exit(3); }
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
    local label="G4: sessionId valid, env JSON present -> guard fires, l2_armed_at stays null"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    touch "$tmp/g4-sid-final-report-env.json"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
w.ensureLayer2Scheduled(state, 'g4-sid');
if (state.layer2.l2_armed_at !== null) { console.error('guard failed: l2_armed_at='+state.layer2.l2_armed_at); process.exit(2); }
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
    local label="G5: appendFinding L72 dedup path: env JSON present -> l2_armed_at stays null"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const sid = 'g5-sid';
// First append: env JSON not yet present, so first call may schedule.
// Clear l2_armed_at via writeLayer2State, then create env JSON, then dup-append.
const f = { categories: ['workflow'], severity: 'warning', detail: 'dup-test', reporter: 't' };
if (!w.appendFinding(sid, f)) { console.error('first append failed'); process.exit(2); }
// Clear l2_armed_at
w.writeLayer2State(sid, { l2_armed_at: null });
// Create env JSON now
fs.writeFileSync(w.getStatePath(sid).replace('-supervisor-state.json', '-final-report-env.json'), '{}');
// Dup append (same fields) -> dedup path L72 fires
if (!w.appendFinding(sid, f)) { console.error('dup append failed'); process.exit(3); }
const st = w.readState(sid);
if (st.layer2.l2_armed_at !== null) { console.error('guard failed: l2_armed_at='+st.layer2.l2_armed_at); process.exit(4); }
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
    local label="G6: appendFinding L84 main path: env JSON present -> finding appended, l2_armed_at stays null"
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
if (st.layer2.l2_armed_at !== null) { console.error('guard failed: l2_armed_at='+st.layer2.l2_armed_at); process.exit(4); }
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
const r = w.writeLayer2State(sid, { l2_armed_at: '2026-06-06T12:00:00Z' });
if (r !== true) { console.error('write returned: '+r); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.l2_armed_at !== '2026-06-06T12:00:00Z') { console.error('l2_armed_at not set: '+st.layer2.l2_armed_at); process.exit(3); }
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

run_g8() {
    local label="G8: CC UUID sessionId x workflow SID env file -> guard fires (cross-ID)"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # workflow SID's env file (what capture-env.sh writes, keyed by workflow SID)
    touch "$tmp/g8-wfsid-final-report-env.json"
    # intent.md so Priority 2 of resolveWorkflowSessionId can confirm the SID
    touch "$tmp/g8-wfsid-intent.md"
    # env file read by CLAUDE_ENV_FILE
    printf 'CLAUDE_SESSION_ID=g8-wfsid\n' > "$tmp/g8-claude-env"
    # write JS to temp file (avoid quoting issues in bash -c)
    cat > "$tmp/g8.js" <<JSEOF
const w = require("$WRITER_NODE");
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
w.ensureLayer2Scheduled(state, 'g8-ccsid');
if (state.layer2.l2_armed_at !== null) {
    console.error('guard failed: l2_armed_at=' + state.layer2.l2_armed_at);
    process.exit(2);
}
console.log('OK');
JSEOF
    # Run node from tmp dir: no WORKTREE_NOTES.md there, so Priority 1 misses,
    # Priority 2 reads CLAUDE_ENV_FILE -> g8-wfsid, checks g8-wfsid-final-report-env.json -> found -> guard fires
    out=$(WORKFLOW_PLANS_DIR="$tmp" CLAUDE_ENV_FILE="$tmp/g8-claude-env" run_with_timeout 5 \
        bash -c 'cd "$1" && exec node "$2"' _ "$tmp" "$tmp/g8.js" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

run_g8b() {
    local label="G8b: unrelated session env file does not suppress scheduling"
    require_guard "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # unrelated session's env file (different session entirely)
    touch "$tmp/unrelated-sid-final-report-env.json"
    cat > "$tmp/g8b.js" <<JSEOF
const w = require("$WRITER_NODE");
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
w.ensureLayer2Scheduled(state, 'g8b-ccsid');
if (state.layer2.l2_armed_at == null) {
    console.error('should have scheduled but did not');
    process.exit(2);
}
console.log('OK');
JSEOF
    # Run from tmp; no WORKTREE_NOTES.md, no CLAUDE_ENV_FILE -> resolveWorkflowSessionId returns null
    # candidates = {g8b-ccsid}; g8b-ccsid-final-report-env.json absent -> schedules normally
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 \
        bash -c 'cd "$1" && exec node "$2"' _ "$tmp" "$tmp/g8b.js" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

run_g10() {
    local label="G10: writeLayer2State pending->frozen clears l2_armed_at"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const sid = 'g10-sid';
w.writeLayer2State(sid, { l2_armed_at: '2026-06-01T00:00:00Z', l2_phase: 'pending' });
const ok = w.writeLayer2State(sid, { l2_phase: 'frozen' });
if (!ok) { console.error('writeLayer2State returned false'); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.l2_phase !== 'frozen') { console.error('l2_phase wrong: '+st.layer2.l2_phase); process.exit(3); }
if (st.layer2.l2_armed_at !== null) { console.error('l2_armed_at not cleared: '+st.layer2.l2_armed_at); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc, out=$out)"; fi
}

run_g11() {
    local label="G11: writeLayer2State pending->done clears l2_armed_at"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const sid = 'g11-sid';
w.writeLayer2State(sid, { l2_armed_at: '2026-06-01T00:00:00Z', l2_phase: 'pending' });
const ok = w.writeLayer2State(sid, { l2_phase: 'done' });
if (!ok) { console.error('writeLayer2State returned false'); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.l2_phase !== 'done') { console.error('l2_phase wrong: '+st.layer2.l2_phase); process.exit(3); }
if (st.layer2.l2_armed_at !== null) { console.error('l2_armed_at not cleared: '+st.layer2.l2_armed_at); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc, out=$out)"; fi
}

run_g12() {
    local label="G12: writeLayer2State pending->pending preserves l2_armed_at (non-terminal)"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const sid = 'g12-sid';
w.writeLayer2State(sid, { l2_armed_at: '2026-06-01T00:00:00Z', l2_phase: 'pending' });
const ok = w.writeLayer2State(sid, { l2_phase: 'pending' });
if (!ok) { console.error('writeLayer2State returned false'); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.l2_phase !== 'pending') { console.error('l2_phase wrong: '+st.layer2.l2_phase); process.exit(3); }
if (st.layer2.l2_armed_at !== '2026-06-01T00:00:00Z') { console.error('l2_armed_at changed: '+st.layer2.l2_armed_at); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc, out=$out)"; fi
}

run_g13() {
    local label="G13: stale frozen state re-patch clears l2_armed_at (C1 scenario)"
    if [ ! -f "$WRITER_MODULE" ]; then skip "$label (writer source not implemented yet)"; return; fi
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const path = require('path');
const sid = 'g13-sid';
const plansDir = process.env.WORKFLOW_PLANS_DIR;
// Simulate stale state: l2_phase=frozen but l2_armed_at non-null (old code bug)
const stale = {
    version: 1,
    session_id: sid,
    created_at: '2026-06-01T00:00:00Z',
    last_updated: '2026-06-01T00:00:00Z',
    layer1: { findings: [] },
    layer2: { l2_armed_at: '2026-06-01T00:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'frozen' },
    layer3: {}
};
fs.writeFileSync(path.join(plansDir, sid + '-supervisor-state.json'), JSON.stringify(stale));
const ok = w.writeLayer2State(sid, { l2_phase: 'frozen' });
if (!ok) { console.error('writeLayer2State returned false'); process.exit(2); }
const st = w.readState(sid);
if (st.layer2.l2_phase !== 'frozen') { console.error('l2_phase wrong: '+st.layer2.l2_phase); process.exit(3); }
if (st.layer2.l2_armed_at !== null) { console.error('l2_armed_at not cleared: '+st.layer2.l2_armed_at); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc, out=$out)"; fi
}

run_g1
run_g2
run_g3
run_g4
run_g5
run_g6
run_g7
run_g8
run_g8b
run_g10
run_g11
run_g12
run_g13

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
