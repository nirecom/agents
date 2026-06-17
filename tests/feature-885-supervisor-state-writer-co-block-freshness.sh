#!/bin/bash
# tests/feature-885-supervisor-state-writer-co-block-freshness.sh
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor-state-writer, co-blocked-by, freshness, axis-a, feature-885
# Tests for issue #885 — back-annotation honors a freshness window:
#   * within last 5 findings AND within 10 seconds: populate co_blocked_by
#   * else: do not back-annotate

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885cf'; }

if [ ! -f "$WRITER" ]; then
    skip "supervisor-state-writer.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

run_node() {
    local label="$1" body="$2"
    local tmpdir
    tmpdir=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then
        tmpdir_node=$(cygpath -m "$tmpdir")
    else
        tmpdir_node="$tmpdir"
    fi
    local out rc
    out=$(WORKFLOW_PLANS_DIR="$tmpdir_node" run_with_timeout 12 node -e "
process.env.WORKFLOW_PLANS_DIR = '$tmpdir_node';
const w = require('$WRITER_NODE');
const fs = require('fs');
const path = require('path');
function statePath(sid) { return path.join('$tmpdir_node', sid+'-supervisor-state.json'); }
function loadState(sid) { return JSON.parse(fs.readFileSync(statePath(sid), 'utf8')); }
function saveState(sid, st) { fs.writeFileSync(statePath(sid), JSON.stringify(st, null, 2), 'utf8'); }
$body
" 2>&1)
    rc=$?
    rm -rf "$tmpdir"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# --- F1: in-window (now-5s) — back-annotates ---------------------------------
run_node "F1: A timestamped ~5s ago: B back-annotates within 10s window" "
w.appendFinding('sid-f1', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on gh issue close 999', reporter: 'enforce-worktree' });
// Age A's timestamp ~5s into the past.
const st0 = loadState('sid-f1');
const oldTs = new Date(Date.now() - 5000).toISOString();
st0.layer1.findings[0].timestamp = oldTs;
saveState('sid-f1', st0);
w.appendFinding('sid-f1', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on gh issue close 999', reporter: 'enforce-issue-close', context: { cwd: '/x' } });
const st = loadState('sid-f1');
if (st.layer1.findings.length !== 2) { console.error('expected 2'); process.exit(2); }
const [a, b] = st.layer1.findings;
if (!Array.isArray(a.co_blocked_by) || !a.co_blocked_by.includes('enforce-issue-close')) {
  console.error('A not back-annotated: '+JSON.stringify(a.co_blocked_by)); process.exit(3);
}
if (!Array.isArray(b.co_blocked_by) || !b.co_blocked_by.includes('enforce-worktree')) {
  console.error('B not back-annotated: '+JSON.stringify(b.co_blocked_by)); process.exit(4);
}
console.log('OK');
"

# --- F2: out-of-window (now-11s) — NO back-annotation -----------------------
run_node "F2: A timestamped ~11s ago: B does NOT back-annotate (out of 10s window)" "
w.appendFinding('sid-f2', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on gh issue close 999', reporter: 'enforce-worktree' });
const st0 = loadState('sid-f2');
const oldTs = new Date(Date.now() - 11000).toISOString();
st0.layer1.findings[0].timestamp = oldTs;
saveState('sid-f2', st0);
w.appendFinding('sid-f2', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on gh issue close 999', reporter: 'enforce-issue-close', context: { cwd: '/x' } });
const st = loadState('sid-f2');
if (st.layer1.findings.length !== 2) { console.error('expected 2'); process.exit(2); }
for (const f of st.layer1.findings) {
  if (Array.isArray(f.co_blocked_by) && f.co_blocked_by.length > 0) {
    console.error('unexpected co_blocked_by out of window: '+JSON.stringify(f.co_blocked_by)); process.exit(3);
  }
}
console.log('OK');
"

# --- F3: beyond last-5 findings — NO back-annotation ------------------------
run_node "F3: 5 unrelated findings between A and B: A out of last-5 → no co_blocked_by" "
w.appendFinding('sid-f3', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on gh issue close 999', reporter: 'enforce-worktree' });
for (let i = 0; i < 5; i++) {
  w.appendFinding('sid-f3', { categories: ['other'], severity: 'notice', detail: 'unrelated '+i, reporter: 'r'+i });
}
w.appendFinding('sid-f3', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on gh issue close 999', reporter: 'enforce-issue-close', context: { cwd: '/x' } });
const st = loadState('sid-f3');
const a = st.layer1.findings[0];
const b = st.layer1.findings[st.layer1.findings.length - 1];
if (Array.isArray(a.co_blocked_by) && a.co_blocked_by.length > 0) {
  console.error('A unexpectedly back-annotated: '+JSON.stringify(a.co_blocked_by)); process.exit(2);
}
if (Array.isArray(b.co_blocked_by) && b.co_blocked_by.length > 0) {
  console.error('B unexpectedly references out-of-window A: '+JSON.stringify(b.co_blocked_by)); process.exit(3);
}
console.log('OK');
"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
