#!/bin/bash
# tests/feature-831-supervisor-emit.sh
# Tests: hooks/lib/supervisor-emit.js
# Tags: supervisor, em-supervisor, layer1, facade, auto-report
# Tests for issue #831 — supervisor-emit.js facade contract.
#
# Verifies the facade module's reportBlock / reportFallback / reportSentinel /
# reportRetrospective helpers map to correct supervisor-state-writer.appendFinding
# taxonomy, that WORKFLOW_ON does NOT emit, and that fail-open guarantees hold
# (no throw when appendFinding errors or when sessionId is empty).
#
# RED: SKIPs all cases while hooks/lib/supervisor-emit.js is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

EMIT_MODULE="$AGENTS_DIR/hooks/lib/supervisor-emit.js"
EMIT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-emit.js"
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

require_source() {
    local p="$1" label="$2"
    if [ ! -f "$p" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Run a node program that stubs appendFinding and invokes the facade.
# stdout is the captured call-record JSON (or 'ERROR:<msg>' on throw).
invoke_emit() {
    local prog="$1"
    run_with_timeout 10 node -e "$prog" 2>&1
}

# Helper to build a node program that intercepts appendFinding by overriding
# Module._cache for the writer, then requires the emit module fresh.
build_stub_prog() {
    local body="$1" throw_flag="$2"
    cat <<NODE
const Module = require('module');
const path = require('path');
const calls = [];
const writerPath = require.resolve('$WRITER_NODE');
require.cache[writerPath] = {
  id: writerPath,
  filename: writerPath,
  loaded: true,
  exports: {
    appendFinding: (sid, finding) => {
      calls.push({ sid, finding });
      if ($throw_flag) { throw new Error('boom'); }
      return true;
    },
    getStatePath: () => '/tmp/x',
    readStateOrInit: () => ({}),
    readState: () => null,
    writeLayer2State: () => true,
  },
};
let emit;
try { emit = require('$EMIT_NODE'); }
catch (e) { console.log('ERROR_REQUIRE:' + e.message); process.exit(0); }
try {
  $body
  console.log(JSON.stringify({ calls }));
} catch (e) {
  console.log('THREW:' + e.message);
}
NODE
}

# Common assertion: given a call record, check the first call matches expected fields.
assert_first_call() {
    local out="$1" expect_categories="$2" expect_severity="$3" expect_reporter="$4" label="$5"
    local check
    check=$(run_with_timeout 5 node -e "
let d = process.argv[1];
try {
  const o = JSON.parse(d);
  const c = o.calls[0];
  if (!c) { console.log('NO_CALL'); process.exit(0); }
  const f = c.finding || {};
  const cats = JSON.stringify((f.categories||[]).slice().sort());
  const want = JSON.stringify(('$expect_categories').split(',').sort());
  if (cats !== want) { console.log('CATS_MISMATCH:'+cats+' vs '+want); process.exit(0); }
  if (f.severity !== '$expect_severity') { console.log('SEV_MISMATCH:'+f.severity); process.exit(0); }
  if (f.reporter !== '$expect_reporter') { console.log('REP_MISMATCH:'+f.reporter); process.exit(0); }
  console.log('OK');
} catch (e) { console.log('PARSE_ERR:'+e.message+' / raw='+d); }
" "$out" 2>&1)
    if [ "$check" = "OK" ]; then pass "$label"
    else fail "$label ($check)"; fi
}

# --- E1: reportBlock enforce-worktree ---
run_e1() {
    require_source "$EMIT_MODULE" "E1: reportBlock(enforce-worktree) emits workflow/warning/enforce-worktree" || return
    local prog out
    prog="$(build_stub_prog "emit.reportBlock('enforce-worktree', 'git push origin main', 'sid-e1');" 0)"
    out=$(invoke_emit "$prog")
    assert_first_call "$out" "workflow" "warning" "enforce-worktree" \
        "E1: reportBlock(enforce-worktree) emits workflow/warning/enforce-worktree"
}

# --- E2: reportBlock workflow-gate ---
run_e2() {
    require_source "$EMIT_MODULE" "E2: reportBlock(workflow-gate) emits workflow/warning/workflow-gate" || return
    local prog out
    prog="$(build_stub_prog "emit.reportBlock('workflow-gate', 'git commit', 'sid-e2');" 0)"
    out=$(invoke_emit "$prog")
    assert_first_call "$out" "workflow" "warning" "workflow-gate" \
        "E2: reportBlock(workflow-gate) emits workflow/warning/workflow-gate"
}

# --- E3: reportBlock enforce-issue-close ---
run_e3() {
    require_source "$EMIT_MODULE" "E3: reportBlock(enforce-issue-close) emits workflow/warning/enforce-issue-close" || return
    local prog out
    prog="$(build_stub_prog "emit.reportBlock('enforce-issue-close', 'gh issue close 1', 'sid-e3');" 0)"
    out=$(invoke_emit "$prog")
    assert_first_call "$out" "workflow" "warning" "enforce-issue-close" \
        "E3: reportBlock(enforce-issue-close) emits workflow/warning/enforce-issue-close"
}

# --- E4: reportFallback ---
run_e4() {
    require_source "$EMIT_MODULE" "E4: reportFallback emits workflow/notice" || return
    local prog out
    prog="$(build_stub_prog "emit.reportFallback('issue-create', 'worktree-notes', 'sid-e4');" 0)"
    out=$(invoke_emit "$prog")
    local check
    check=$(run_with_timeout 5 node -e "
const o = JSON.parse(process.argv[1]);
const f = (o.calls[0]||{}).finding||{};
const cats = JSON.stringify((f.categories||[]).slice().sort());
if (cats !== '[\"workflow\"]') { console.log('CATS:'+cats); process.exit(0); }
if (f.severity !== 'notice') { console.log('SEV:'+f.severity); process.exit(0); }
console.log('OK');
" "$out" 2>&1)
    [ "$check" = "OK" ] && pass "E4: reportFallback emits workflow/notice" \
        || fail "E4: reportFallback emits workflow/notice ($check)"
}

# --- E5: reportSentinel WORKFLOW_OFF ---
run_e5() {
    require_source "$EMIT_MODULE" "E5: reportSentinel(WORKFLOW_OFF) emits workflow/warning/enforce-override-handlers" || return
    local prog out
    prog="$(build_stub_prog "emit.reportSentinel('WORKFLOW_OFF', 'trivial typo', 'sid-e5');" 0)"
    out=$(invoke_emit "$prog")
    assert_first_call "$out" "workflow" "warning" "enforce-override-handlers" \
        "E5: reportSentinel(WORKFLOW_OFF) emits workflow/warning/enforce-override-handlers"
}

# --- E6: reportSentinel WORKFLOW_ON ---
run_e6() {
    require_source "$EMIT_MODULE" "E6: reportSentinel(WORKFLOW_ON) does NOT emit a finding" || return
    local prog out
    prog="$(build_stub_prog "emit.reportSentinel('WORKFLOW_ON', 'restore', 'sid-e6');" 0)"
    out=$(invoke_emit "$prog")
    local check
    check=$(run_with_timeout 5 node -e "
const o = JSON.parse(process.argv[1]);
if ((o.calls||[]).length !== 0) { console.log('UNEXPECTED_CALLS:'+o.calls.length); process.exit(0); }
console.log('OK');
" "$out" 2>&1)
    [ "$check" = "OK" ] && pass "E6: reportSentinel(WORKFLOW_ON) does NOT emit a finding" \
        || fail "E6: reportSentinel(WORKFLOW_ON) does NOT emit a finding ($check)"
}

# --- E7: reportRetrospective ---
run_e7() {
    require_source "$EMIT_MODULE" "E7: reportRetrospective emits other/notice/session-close" || return
    local prog out
    prog="$(build_stub_prog "emit.reportRetrospective('post-session observation', 'sid-e7');" 0)"
    out=$(invoke_emit "$prog")
    assert_first_call "$out" "other" "notice" "session-close" \
        "E7: reportRetrospective emits other/notice/session-close"
}

# --- E8: fail-open when appendFinding throws ---
run_e8() {
    require_source "$EMIT_MODULE" "E8: facade is fail-open when appendFinding throws" || return
    local prog out
    prog="$(build_stub_prog "
const r1 = emit.reportBlock('enforce-worktree', 'cmd', 'sid-e8');
const r2 = emit.reportFallback('skill', 'fb', 'sid-e8');
const r3 = emit.reportSentinel('WORKFLOW_OFF', 'r', 'sid-e8');
const r4 = emit.reportRetrospective('obs', 'sid-e8');
if (r1 !== undefined || r2 !== undefined || r3 !== undefined || r4 !== undefined) {
  console.log('NON_UNDEFINED');
}
" 1)"
    out=$(invoke_emit "$prog")
    if echo "$out" | grep -q "THREW:"; then
        fail "E8: facade is fail-open when appendFinding throws (re-threw: $out)"
    elif echo "$out" | grep -q "NON_UNDEFINED"; then
        fail "E8: facade is fail-open when appendFinding throws (returned non-undefined)"
    else
        pass "E8: facade is fail-open when appendFinding throws"
    fi
}

# --- E9: fail-open when sessionId is null/undefined/empty ---
run_e9() {
    require_source "$EMIT_MODULE" "E9: facade is fail-open on null/undefined/empty sessionId" || return
    local prog out
    prog="$(build_stub_prog "
const results = [];
results.push(emit.reportBlock('enforce-worktree', 'cmd', null));
results.push(emit.reportBlock('enforce-worktree', 'cmd', undefined));
results.push(emit.reportBlock('enforce-worktree', 'cmd', ''));
results.push(emit.reportFallback('skill', 'fb', null));
results.push(emit.reportSentinel('WORKFLOW_OFF', 'r', ''));
results.push(emit.reportRetrospective('obs', undefined));
if (results.some(r => r !== undefined)) console.log('NON_UNDEFINED');
" 0)"
    out=$(invoke_emit "$prog")
    if echo "$out" | grep -q "THREW:"; then
        fail "E9: facade is fail-open on null/undefined/empty sessionId (threw: $out)"
    elif echo "$out" | grep -q "NON_UNDEFINED"; then
        fail "E9: facade is fail-open on null/undefined/empty sessionId (returned non-undefined)"
    else
        # Also verify no calls were made (empty sid must short-circuit)
        local check
        check=$(run_with_timeout 5 node -e "
const m = process.argv[1].match(/\{\"calls\":.*\}/);
if (!m) { console.log('OK'); process.exit(0); }
const o = JSON.parse(m[0]);
if ((o.calls||[]).length === 0) console.log('OK');
else console.log('UNEXPECTED_CALLS:'+o.calls.length);
" "$out" 2>&1)
        [ "$check" = "OK" ] && pass "E9: facade is fail-open on null/undefined/empty sessionId" \
            || fail "E9: facade is fail-open on null/undefined/empty sessionId ($check)"
    fi
}

run_e1
run_e2
run_e3
run_e4
run_e5
run_e6
run_e7
run_e8
run_e9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
