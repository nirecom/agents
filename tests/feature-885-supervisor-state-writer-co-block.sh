#!/bin/bash
# tests/feature-885-supervisor-state-writer-co-block.sh
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor-state-writer, co-blocked-by, back-annotation, axis-a, feature-885
# Tests for issue #885 — appendFinding back-annotates co_blocked_by when the
# same command is blocked by a different hook within the freshness window.

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885cb'; }

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
    out=$(WORKFLOW_PLANS_DIR="$tmpdir_node" run_with_timeout 8 node -e "
process.env.WORKFLOW_PLANS_DIR = '$tmpdir_node';
const w = require('$WRITER_NODE');
const fs = require('fs');
const path = require('path');
function loadState(sid) {
  return JSON.parse(fs.readFileSync(path.join('$tmpdir_node', sid+'-supervisor-state.json'), 'utf8'));
}
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

# --- C1: A→B back-annotation (different reporters, same detail) -------------
run_node "C1: A then B with same detail back-annotates BOTH co_blocked_by" "
w.appendFinding('sid-c1', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on gh issue close 999', reporter: 'enforce-worktree' });
w.appendFinding('sid-c1', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on gh issue close 999', reporter: 'enforce-issue-close', context: { cwd: '/x' } });
const st = loadState('sid-c1');
// Detail differs because each hook prefixes its own name. The back-annotation
// must rely on a shared key (e.g., command extracted from detail, or a
// dedicated extras field). For this test we additionally pass context.cwd to
// ensure cross-reporter even with non-identical detail. Adjust if writer uses
// a different correlation key.
if (st.layer1.findings.length !== 2) { console.error('expected 2 findings, got '+st.layer1.findings.length); process.exit(2); }
const [f0, f1] = st.layer1.findings;
if (!Array.isArray(f0.co_blocked_by) || !f0.co_blocked_by.includes('enforce-issue-close')) {
  console.error('f0.co_blocked_by='+JSON.stringify(f0.co_blocked_by)); process.exit(3);
}
if (!Array.isArray(f1.co_blocked_by) || !f1.co_blocked_by.includes('enforce-worktree')) {
  console.error('f1.co_blocked_by='+JSON.stringify(f1.co_blocked_by)); process.exit(4);
}
console.log('OK');
"

# --- C2: Same reporter twice -> deduped (no co_blocked_by) ------------------
run_node "C2: same reporter twice is deduped; no co_blocked_by" "
w.appendFinding('sid-c2', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on cmd1', reporter: 'enforce-worktree' });
w.appendFinding('sid-c2', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on cmd1', reporter: 'enforce-worktree' });
const st = loadState('sid-c2');
if (st.layer1.findings.length !== 1) { console.error('expected 1 (deduped), got '+st.layer1.findings.length); process.exit(2); }
const f = st.layer1.findings[0];
if (Array.isArray(f.co_blocked_by) && f.co_blocked_by.length > 0) {
  console.error('unexpected co_blocked_by'); process.exit(3);
}
console.log('OK');
"

# --- C3: Different commands -> no cross co_blocked_by -----------------------
run_node "C3: different commands across reporters: no cross co_blocked_by" "
w.appendFinding('sid-c3', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on cmd1', reporter: 'enforce-worktree' });
w.appendFinding('sid-c3', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on cmd2', reporter: 'enforce-issue-close' });
const st = loadState('sid-c3');
if (st.layer1.findings.length !== 2) { console.error('expected 2'); process.exit(2); }
for (const f of st.layer1.findings) {
  if (Array.isArray(f.co_blocked_by) && f.co_blocked_by.length > 0) {
    console.error('unexpected co_blocked_by for distinct commands: '+JSON.stringify(f)); process.exit(3);
  }
}
console.log('OK');
"

# --- C4: Idempotency — running the same A→B sequence twice doesn't dup ------
run_node "C4: idempotent co_blocked_by (no duplicates on re-run)" "
function pair() {
  w.appendFinding('sid-c4', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-worktree on gh issue close 999', reporter: 'enforce-worktree' });
  w.appendFinding('sid-c4', { categories: ['workflow'], severity: 'warning', detail: 'hook blocked: enforce-issue-close on gh issue close 999', reporter: 'enforce-issue-close', context: { cwd: '/x' } });
}
pair();
pair();
const st = loadState('sid-c4');
// Second pair should be deduped (same reporter+detail+severity+categories already present).
for (const f of st.layer1.findings) {
  if (Array.isArray(f.co_blocked_by)) {
    const seen = new Set();
    for (const r of f.co_blocked_by) {
      if (seen.has(r)) { console.error('duplicate in co_blocked_by: '+r); process.exit(2); }
      seen.add(r);
    }
  }
}
console.log('OK');
"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
