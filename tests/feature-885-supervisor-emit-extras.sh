#!/bin/bash
# tests/feature-885-supervisor-emit-extras.sh
# Tests: hooks/lib/supervisor-emit.js
# Tags: supervisor-emit, reportBlock-extras, axis-a, feature-885
# Tests for issue #885 — reportBlock() gains a 4th optional extras parameter.
#
# Signature change: reportBlock(hook, command, sessionId, extras?)
# extras schema: { reason?: string, context?: { cwd?: string, git_root_resolved?: boolean }, co_blocked_by?: string[] }
# Invalid/empty extras silently ignored (fail-open).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

EMIT_MODULE="$AGENTS_DIR/hooks/lib/supervisor-emit.js"
EMIT_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-emit.js"

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

if [ ! -f "$EMIT_MODULE" ]; then
    skip "supervisor-emit.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Create a temp WORKFLOW_PLANS_DIR per case to isolate state.
make_tmp() {
    mktemp -d 2>/dev/null || mktemp -d -t 'feat885'
}

# run_case <label> <session> <emit-call-js> <assert-js>
# emit-call-js: JS code that invokes emit.reportBlock(...). Should return nothing meaningful.
# assert-js:    JS code that reads the state JSON variable `state` and prints 'OK' or fails.
run_case() {
    local label="$1" sid="$2" call_js="$3" assert_js="$4"
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
const emit = require('$EMIT_MODULE_NODE');
const fs = require('fs');
const path = require('path');
$call_js
const statePath = path.join('$tmpdir_node', '${sid}-supervisor-state.json');
let state = null;
try { state = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch (_) {}
$assert_js
" 2>&1)
    rc=$?
    rm -rf "$tmpdir"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# --- E1: 3-arg call (backward compat) — no extra fields ---------------------
run_case "E1: 3-arg reportBlock produces finding without reason/context/co_blocked_by" \
"sid-e1" \
"emit.reportBlock('test-hook', 'gh issue close 1', 'sid-e1');" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if ('reason' in f) { console.error('unexpected reason field'); process.exit(4); }
if ('context' in f) { console.error('unexpected context field'); process.exit(5); }
if ('co_blocked_by' in f) { console.error('unexpected co_blocked_by field'); process.exit(6); }
console.log('OK');"

# --- E2: extras.reason populated --------------------------------------------
run_case "E2: extras.reason='cwd_no_git_root' populates finding.reason" \
"sid-e2" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e2', { reason: 'cwd_no_git_root' });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if (f.reason !== 'cwd_no_git_root') { console.error('reason='+JSON.stringify(f.reason)); process.exit(4); }
console.log('OK');"

# --- E3: extras.context populated -------------------------------------------
run_case "E3: extras.context populates finding.context" \
"sid-e3" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e3', { context: { cwd: '/tmp/x', git_root_resolved: true } });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if (!f.context || f.context.cwd !== '/tmp/x' || f.context.git_root_resolved !== true) {
  console.error('context='+JSON.stringify(f.context)); process.exit(4);
}
console.log('OK');"

# --- E4: extras.co_blocked_by populated -------------------------------------
run_case "E4: extras.co_blocked_by populates finding.co_blocked_by" \
"sid-e4" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e4', { co_blocked_by: ['enforce-issue-close'] });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if (!Array.isArray(f.co_blocked_by) || f.co_blocked_by[0] !== 'enforce-issue-close') {
  console.error('co_blocked_by='+JSON.stringify(f.co_blocked_by)); process.exit(4);
}
console.log('OK');"

# --- E5: extras as string (invalid type) silently ignored ------------------
run_case "E5: extras as string silently ignored — finding has no extra fields" \
"sid-e5" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e5', 'oops');" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if ('reason' in f) { console.error('unexpected reason'); process.exit(4); }
if ('context' in f) { console.error('unexpected context'); process.exit(5); }
if ('co_blocked_by' in f) { console.error('unexpected co_blocked_by'); process.exit(6); }
console.log('OK');"

# --- E6: extras.reason='' omitted -------------------------------------------
run_case "E6: empty reason='' is NOT included in finding" \
"sid-e6" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e6', { reason: '' });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if ('reason' in f) { console.error('reason should be absent'); process.exit(4); }
console.log('OK');"

# --- E7: extra keys in context filtered out ---------------------------------
run_case "E7: only cwd/git_root_resolved pass; other keys filtered" \
"sid-e7" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e7', { context: { cwd: '/x', git_root_resolved: true, mainCheckoutDetection: 'foo' } });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if (!f.context) { console.error('no context'); process.exit(4); }
if ('mainCheckoutDetection' in f.context) { console.error('extra key leaked'); process.exit(5); }
if (f.context.cwd !== '/x' || f.context.git_root_resolved !== true) { console.error('cwd/resolved wrong'); process.exit(6); }
console.log('OK');"

# --- E8: co_blocked_by empty array omitted ----------------------------------
run_case "E8: co_blocked_by=[] key omitted from finding" \
"sid-e8" \
"emit.reportBlock('test-hook', 'cmd', 'sid-e8', { co_blocked_by: [] });" \
"if (!state) { console.error('no state'); process.exit(2); }
const f = state.layer1.findings[0];
if (!f) { console.error('no finding'); process.exit(3); }
if ('co_blocked_by' in f) { console.error('co_blocked_by should be absent when []'); process.exit(4); }
console.log('OK');"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
