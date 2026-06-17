#!/bin/bash
# tests/feature-885-supervisor-state-writer-dedupe.sh
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor-state-writer, dedupe, axis-a, feature-885
# Tests for issue #885 — dedupe key extended to include reason and
# context.git_root_resolved.
#
# Current key (pre-#885): categories+severity+detail+reporter
# New key (post-#885):    categories+severity+detail+reporter+reason+context.git_root_resolved

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat885dd'; }

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
function loadState(sid) { return JSON.parse(fs.readFileSync(path.join('$tmpdir_node', sid+'-supervisor-state.json'), 'utf8')); }
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

# --- D1: same command+reporter+reason → deduped to 1 ------------------------
run_node "D1: same detail+reporter+reason → 1 finding (deduped)" "
const base = { categories: ['workflow'], severity: 'warning', detail: 'd1', reporter: 'r1', reason: 'cwd_no_git_root' };
w.appendFinding('sid-d1', base);
w.appendFinding('sid-d1', base);
const st = loadState('sid-d1');
if (st.layer1.findings.length !== 1) { console.error('expected 1, got '+st.layer1.findings.length); process.exit(2); }
console.log('OK');
"

# --- D2: same command+reporter, DIFFERENT reason → 2 findings ---------------
run_node "D2: same detail+reporter, different reason → 2 findings" "
w.appendFinding('sid-d2', { categories: ['workflow'], severity: 'warning', detail: 'd2', reporter: 'r1', reason: 'cwd_no_git_root' });
w.appendFinding('sid-d2', { categories: ['workflow'], severity: 'warning', detail: 'd2', reporter: 'r1', reason: 'isMainCheckout_unresolved' });
const st = loadState('sid-d2');
if (st.layer1.findings.length !== 2) { console.error('expected 2, got '+st.layer1.findings.length); process.exit(2); }
console.log('OK');
"

# --- D3: same key + different context.git_root_resolved → 2 findings --------
run_node "D3: same detail+reporter+reason, different context.git_root_resolved → 2 findings" "
w.appendFinding('sid-d3', { categories: ['workflow'], severity: 'warning', detail: 'd3', reporter: 'r1', reason: 'cwd_no_git_root', context: { git_root_resolved: false } });
w.appendFinding('sid-d3', { categories: ['workflow'], severity: 'warning', detail: 'd3', reporter: 'r1', reason: 'cwd_no_git_root', context: { git_root_resolved: true } });
const st = loadState('sid-d3');
if (st.layer1.findings.length !== 2) { console.error('expected 2, got '+st.layer1.findings.length); process.exit(2); }
console.log('OK');
"

# --- D4: identical key including context.git_root_resolved → 1 finding ------
run_node "D4: identical key incl. context.git_root_resolved → 1 finding (deduped)" "
const base = { categories: ['workflow'], severity: 'warning', detail: 'd4', reporter: 'r1', reason: 'cwd_no_git_root', context: { git_root_resolved: true } };
w.appendFinding('sid-d4', base);
w.appendFinding('sid-d4', base);
const st = loadState('sid-d4');
if (st.layer1.findings.length !== 1) { console.error('expected 1, got '+st.layer1.findings.length); process.exit(2); }
console.log('OK');
"

# --- D5: backward compat — old finding (no context) + new (with context) ---
run_node "D5: old finding without context + new with context.git_root_resolved → 2 findings (upgrade window)" "
w.appendFinding('sid-d5', { categories: ['workflow'], severity: 'warning', detail: 'd5', reporter: 'r1', reason: 'cwd_no_git_root' });
w.appendFinding('sid-d5', { categories: ['workflow'], severity: 'warning', detail: 'd5', reporter: 'r1', reason: 'cwd_no_git_root', context: { git_root_resolved: true } });
const st = loadState('sid-d5');
if (st.layer1.findings.length !== 2) { console.error('expected 2 (compat split), got '+st.layer1.findings.length); process.exit(2); }
console.log('OK');
"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
