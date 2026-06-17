#!/bin/bash
# tests/feature-929-supervisor-finding-status.sh
# Tests: hooks/lib/supervisor-finding-status.js
# Tags: supervisor, em-supervisor, finding-status, codex-review, unit
# RED for issue #929.
#
# L3 gap (what this test does NOT catch):
# - real supervisor agent invoking the full flow inside a live Claude Code session
# - Codex API network call succeeding end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

FS_MODULE="$AGENTS_DIR/hooks/lib/supervisor-finding-status.js"
FS_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-finding-status.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_function_exists() {
    local fn="$1" label="$2"
    if [ ! -f "$FS_MODULE" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    local probe
    probe=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
process.stdout.write(typeof m.$fn === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label ($fn not implemented yet)"; return 1
    fi
    return 0
}

run_fs1() {
    require_function_exists "appendDraftFinding" "FS1: appendDraftFinding adds status:draft with auto idx" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['intent'], severity:'warning', detail:'a', reporter:'x', status:'confirmed' },
  { idx:1, categories:['code'],   severity:'warning', detail:'b', reporter:'x', status:'confirmed' },
] } };
m.appendDraftFinding(state, { categories:['workflow'], severity:'error', detail:'c', reporter:'supervisor' });
const f = state.layer2.findings;
if (f.length !== 3) { console.error('len='+f.length); process.exit(2); }
const last = f[2];
if (last.status !== 'draft') { console.error('status='+last.status); process.exit(3); }
if (last.idx !== 2) { console.error('idx='+last.idx); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS1: appendDraftFinding adds status:draft with auto idx"
    else
        fail "FS1: appendDraftFinding adds status:draft with auto idx (rc=$rc, out=$out)"
    fi
}

run_fs2() {
    require_function_exists "appendDraftFinding" "FS2: appendDraftFinding on empty findings → idx=0" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [] } };
m.appendDraftFinding(state, { categories:['intent'], severity:'notice', detail:'x', reporter:'supervisor' });
const f = state.layer2.findings;
if (f.length !== 1) { console.error('len='+f.length); process.exit(2); }
if (f[0].idx !== 0) { console.error('idx='+f[0].idx); process.exit(3); }
if (f[0].status !== 'draft') { console.error('status='+f[0].status); process.exit(4); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS2: appendDraftFinding on empty findings → idx=0"
    else
        fail "FS2: appendDraftFinding on empty findings → idx=0 (rc=$rc, out=$out)"
    fi
}

run_fs3() {
    require_function_exists "confirmFinding" "FS3: confirmFinding sets status:confirmed on matching idx" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['intent'], severity:'warning', detail:'a', reporter:'x', status:'draft' },
  { idx:1, categories:['code'],   severity:'warning', detail:'b', reporter:'x', status:'draft' },
] } };
m.confirmFinding(state, 1);
const f = state.layer2.findings;
if (f[0].status !== 'draft') { console.error('idx0 mutated: '+f[0].status); process.exit(2); }
if (f[1].status !== 'confirmed') { console.error('idx1: '+f[1].status); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS3: confirmFinding sets status:confirmed on matching idx"
    else
        fail "FS3: confirmFinding sets status:confirmed on matching idx (rc=$rc, out=$out)"
    fi
}

run_fs4() {
    require_function_exists "confirmFinding" "FS4: confirmFinding non-existent idx → no-op" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['intent'], severity:'warning', detail:'a', reporter:'x', status:'draft' },
] } };
const before = JSON.stringify(state);
try {
  m.confirmFinding(state, 99);
} catch (e) {
  console.error('threw: '+e.message); process.exit(2);
}
const after = JSON.stringify(state);
if (before !== after) { console.error('state mutated'); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS4: confirmFinding non-existent idx → no-op"
    else
        fail "FS4: confirmFinding non-existent idx → no-op (rc=$rc, out=$out)"
    fi
}

run_fs5() {
    require_function_exists "dropFindings" "FS5: dropFindings removes at indices (descending-safe)" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['a'], severity:'warning', detail:'A', reporter:'x', status:'draft' },
  { idx:1, categories:['b'], severity:'warning', detail:'B', reporter:'x', status:'draft' },
  { idx:2, categories:['c'], severity:'warning', detail:'C', reporter:'x', status:'draft' },
  { idx:3, categories:['d'], severity:'warning', detail:'D', reporter:'x', status:'draft' },
] } };
m.dropFindings(state, [0, 2]);
const f = state.layer2.findings;
if (f.length !== 2) { console.error('len='+f.length); process.exit(2); }
const details = f.map(x => x.detail).join(',');
if (details !== 'B,D') { console.error('details='+details); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS5: dropFindings removes at indices (descending-safe)"
    else
        fail "FS5: dropFindings removes at indices (descending-safe) (rc=$rc, out=$out)"
    fi
}

run_fs6() {
    require_function_exists "dropFindings" "FS6: dropFindings with empty list → no-op" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['a'], severity:'warning', detail:'A', reporter:'x', status:'draft' },
] } };
const before = JSON.stringify(state);
m.dropFindings(state, []);
const after = JSON.stringify(state);
if (before !== after) { console.error('state mutated'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS6: dropFindings with empty list → no-op"
    else
        fail "FS6: dropFindings with empty list → no-op (rc=$rc, out=$out)"
    fi
}

run_fs7() {
    require_function_exists "dropFindings" "FS7: dropFindings with duplicate idxs removes each once" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['a'], severity:'warning', detail:'A', reporter:'x', status:'draft' },
  { idx:1, categories:['b'], severity:'warning', detail:'B', reporter:'x', status:'draft' },
  { idx:2, categories:['c'], severity:'warning', detail:'C', reporter:'x', status:'draft' },
] } };
m.dropFindings(state, [1, 1, 1]);
const f = state.layer2.findings;
if (f.length !== 2) { console.error('len='+f.length); process.exit(2); }
const details = f.map(x => x.detail).join(',');
if (details !== 'A,C') { console.error('details='+details); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS7: dropFindings with duplicate idxs removes each once"
    else
        fail "FS7: dropFindings with duplicate idxs removes each once (rc=$rc, out=$out)"
    fi
}

run_fs8() {
    require_function_exists "promotePendingDraftsToConfirmed" "FS8: promotePendingDraftsToConfirmed promotes all drafts" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['a'], severity:'warning', detail:'A', reporter:'x', status:'draft' },
  { idx:1, categories:['b'], severity:'warning', detail:'B', reporter:'x', status:'confirmed' },
  { idx:2, categories:['c'], severity:'warning', detail:'C', reporter:'x', status:'draft' },
] } };
m.promotePendingDraftsToConfirmed(state);
const f = state.layer2.findings;
if (!f.every(x => x.status === 'confirmed')) {
  console.error('statuses='+JSON.stringify(f.map(x => x.status))); process.exit(2);
}
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS8: promotePendingDraftsToConfirmed promotes all drafts"
    else
        fail "FS8: promotePendingDraftsToConfirmed promotes all drafts (rc=$rc, out=$out)"
    fi
}

run_fs9() {
    require_function_exists "promotePendingDraftsToConfirmed" "FS9: promotePendingDraftsToConfirmed with no drafts → no-op" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$FS_NODE');
const state = { layer2: { findings: [
  { idx:0, categories:['a'], severity:'warning', detail:'A', reporter:'x', status:'confirmed' },
  { idx:1, categories:['b'], severity:'warning', detail:'B', reporter:'x', status:'confirmed' },
] } };
const before = JSON.stringify(state);
m.promotePendingDraftsToConfirmed(state);
const after = JSON.stringify(state);
if (before !== after) { console.error('state mutated'); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "FS9: promotePendingDraftsToConfirmed with no drafts → no-op"
    else
        fail "FS9: promotePendingDraftsToConfirmed with no drafts → no-op (rc=$rc, out=$out)"
    fi
}

run_fs1
run_fs2
run_fs3
run_fs4
run_fs5
run_fs6
run_fs7
run_fs8
run_fs9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
