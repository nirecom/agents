#!/bin/bash
# tests/feature-1255-supervisor-block-severity.sh
# Tests: hooks/lib/supervisor-emit.js hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, layer1, reportBlock, severity, class-dedup, feature-1255, scope:issue-specific
# Tests for issue #1255 — reportBlock severity notice (打ち手1) + session-wide
# class dedup for block findings (打ち手2).
#
# 打ち手1: reportBlock() severity changes "error" → "notice" so a hook block
#          alone does NOT arm alert mode (notice short-circuit at
#          ensureAlertScheduled line 116).
# 打ち手2: appendFinding() gains session-wide class dedup for block findings:
#          same command across different reporters collapses to one finding
#          carrying class_dedup_count.
#
# NOTE: These assert FUTURE behavior. Some cases FAIL against current source
# (reportBlock still "error"; no class dedup yet) — that is expected and
# correct; they are regression tests for the upcoming source changes.
#
# L3 gap: These are L2 tests — they call reportBlock/reportFallback directly
# via Node.js require without spawning a real hook subprocess. A full L3 test
# would additionally catch: (1) enforce-worktree.js actually calling reportBlock
# as a child process and the resulting IPC/env propagation working end-to-end;
# (2) the real WORKFLOW_PLANS_DIR env var being resolved inside the hook's own
# process rather than the test's injected env; (3) timing-dependent consecutive
# dedup under concurrent hook firings in a real claude -p session.
# Risk category: hook-registration (L3 required for full confidence).
# Tracked in #1255 scope.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

EMIT="$AGENTS_DIR/hooks/lib/supervisor-emit.js"
EMIT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-emit.js"
WRITER="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
COLLECT="$AGENTS_DIR/hooks/lib/supervisor-guard/collect-audit-triggers.js"
COLLECT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-guard/collect-audit-triggers.js"

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat1255'; }

if [ ! -f "$EMIT" ] || [ ! -f "$WRITER" ] || [ ! -f "$COLLECT" ]; then
    skip "supervisor source not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Run a node body with a fresh WORKFLOW_PLANS_DIR. The body has:
#   emit    — supervisor-emit facade
#   w       — supervisor-state-writer
#   collect — collect-audit-triggers
#   loadState(sid) — read the state file back
# Expected: body prints exactly "OK" on success (any other stdout/nonzero = fail).
run_node() {
    local label="$1" body="$2"
    local tmpdir tmpdir_node out rc
    tmpdir=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then
        tmpdir_node=$(cygpath -m "$tmpdir")
    else
        tmpdir_node="$tmpdir"
    fi
    out=$(WORKFLOW_PLANS_DIR="$tmpdir_node" run_with_timeout 10 node -e "
process.env.WORKFLOW_PLANS_DIR = '$tmpdir_node';
const emit = require('$EMIT_NODE');
const w = require('$WRITER_NODE');
const collect = require('$COLLECT_NODE');
const fs = require('fs');
const path = require('path');
function loadState(sid) {
  const p = path.join('$tmpdir_node', sid + '-supervisor-state.json');
  return JSON.parse(fs.readFileSync(p, 'utf8'));
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

# --- AC-A: reportBlock does NOT arm alert (notice short-circuit) -------------
run_node "AC-A: reportBlock → alert.alert_armed_at === null (notice does not arm)" "
emit.reportBlock('some-hook', 'some-cmd', 'sid-aca');
const st = w.readState('sid-aca');
if (!st) { console.error('no state written'); process.exit(2); }
if (st.alert.alert_armed_at !== null) { console.error('expected null armed_at, got '+JSON.stringify(st.alert.alert_armed_at)); process.exit(2); }
console.log('OK');
"

# --- AC-B: collectAuditCandidates on notice-only state → shouldArm false -----
run_node "AC-B: collectAuditCandidates([], state) → shouldArm === false" "
emit.reportBlock('some-hook', 'some-cmd', 'sid-acb');
const st = w.readState('sid-acb');
if (!st) { console.error('no state written'); process.exit(2); }
const res = collect.collectAuditCandidates([], st);
if (res.shouldArm !== false) { console.error('expected shouldArm false, got '+JSON.stringify(res)); process.exit(2); }
console.log('OK');
"

# --- AC-C: many reportBlock calls still never arm alert ----------------------
run_node "AC-C: multiple reportBlock (distinct cmds) → alert_armed_at stays null" "
emit.reportBlock('some-hook', 'cmd-1', 'sid-acc');
emit.reportBlock('some-hook', 'cmd-2', 'sid-acc');
emit.reportBlock('some-hook', 'cmd-3', 'sid-acc');
const st = w.readState('sid-acc');
if (!st) { console.error('no state written'); process.exit(2); }
if (st.alert.alert_armed_at !== null) { console.error('expected null armed_at, got '+JSON.stringify(st.alert.alert_armed_at)); process.exit(2); }
console.log('OK');
"

# --- AC-D: reportFallback (warning) DOES arm alert ---------------------------
# Symmetric classifier test: the notice short-circuit must NOT suppress
# warning-severity findings. reportFallback emits severity:"warning" →
# ensureAlertScheduled arms alert_armed_at.
run_node "AC-D: reportFallback (warning) → alert_armed_at !== null (warning still arms)" "
emit.reportFallback('skillA', 'worktree-notes', 'sid-acd');
const st = w.readState('sid-acd');
if (!st) { console.error('no state written'); process.exit(2); }
if (st.alert.alert_armed_at === null) { console.error('expected non-null armed_at for warning, got null'); process.exit(2); }
console.log('OK');
"

# --- DED-1: same reporter + same command consecutive → 1 finding -------------
run_node "DED-1: same reporter+command consecutive → 1 finding (consecutive dedup)" "
emit.reportBlock('r1', 'cmd-x', 'sid-ded1');
emit.reportBlock('r1', 'cmd-x', 'sid-ded1');
const st = loadState('sid-ded1');
const n = st.layer1.findings.length;
if (n !== 1) { console.error('expected 1 finding, got '+n); process.exit(2); }
console.log('OK');
"

# --- DED-2: same reporter + same command, non-consecutive → class dedup -------
# Class key = reporter + "|" + command. Three calls from r1:
#   r1+cmd-x → finding 1; r1+cmd-y → finding 2 (breaks consecutive); r1+cmd-x again
# → class dedup fires on third call (same reporter+cmd-x class, non-consecutive).
# Result: 2 findings total (cmd-x retained with class_dedup_count=2; cmd-y standalone).
# Different reporters on the same command (r1+cmd-x vs r2+cmd-x) have distinct class
# keys and are NOT collapsed — they may form co-block pairs (tested in feature-885).
run_node "DED-2: same reporter+command non-consecutive → 2 findings; first has class_dedup_count === 2" "
emit.reportBlock('r1', 'cmd-x', 'sid-ded2');
emit.reportBlock('r1', 'cmd-y', 'sid-ded2');
emit.reportBlock('r1', 'cmd-x', 'sid-ded2');
const st = loadState('sid-ded2');
const n = st.layer1.findings.length;
if (n !== 2) { console.error('expected 2 findings, got '+n+': '+JSON.stringify(st.layer1.findings.map(f => f.detail))); process.exit(2); }
const withCount = st.layer1.findings.find(f => f.class_dedup_count === 2);
if (!withCount) { console.error('expected a finding with class_dedup_count === 2, got '+JSON.stringify(st.layer1.findings.map(f => f.class_dedup_count))); process.exit(2); }
console.log('OK');
"

# --- DED-3: non-block findings are NOT class-deduped -------------------------
# Fallback findings (reportFallback) have detail 'fallback taken: <name>' and
# carry no 'hook blocked:' prefix. Interleaving a block breaks consecutive
# dedup, so two identical fallbacks remain two findings — class dedup applies
# to block findings only.
run_node "DED-3: non-block (fallback) findings NOT class-deduped → 2 fallback findings" "
emit.reportFallback('skillA', 'fallbackA', 'sid-ded3');
emit.reportBlock('enforce-worktree', 'git commit', 'sid-ded3');
emit.reportFallback('skillA', 'fallbackA', 'sid-ded3');
const st = loadState('sid-ded3');
const fb = st.layer1.findings.filter(f => typeof f.detail === 'string' && f.detail.indexOf('fallback taken:') === 0);
if (fb.length !== 2) { console.error('expected 2 fallback findings, got '+fb.length+' details='+JSON.stringify(st.layer1.findings.map(f => f.detail))); process.exit(2); }
console.log('OK');
"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
