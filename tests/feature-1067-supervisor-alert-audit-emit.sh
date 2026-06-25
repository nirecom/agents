#!/bin/bash
# tests/feature-1067-supervisor-alert-audit-emit.sh
# Tests: hooks/lib/supervisor-emit.js
# Tags: supervisor, em-supervisor, emit, severity, scope:issue-specific
# Tests for issue #1067 — supervisor-emit severity re-grading contract.
# Cases: reportBlock emits error; reportFallback emits warning.
#
# RED: Fails until source changes land (reportBlock still emits warning, reportFallback still emits notice).

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
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

build_emit_stub() {
    local body="$1"
    cat <<NODE
const calls = [];
const writerPath = require.resolve('$WRITER_NODE');
require.cache[writerPath] = {
  id: writerPath, filename: writerPath, loaded: true,
  exports: { appendFinding: (sid, f) => { calls.push({ sid, finding: f }); return true; }, getStatePath: () => '/tmp/x', readStateOrInit: () => ({}), readState: () => null, writeLayer2State: () => true },
};
let emit;
try { emit = require('$EMIT_NODE'); }
catch (e) { console.log('ERROR_REQUIRE:' + e.message); process.exit(0); }
try { $body; console.log(JSON.stringify({ calls })); } catch (e) { console.log('THREW:'+e.message); }
NODE
}

# EM1: reportBlock emits severity:"error"
run_em1() {
    require_source "$EMIT_MODULE" "EM1: reportBlock emits severity:error" || return
    local prog out check
    prog="$(build_emit_stub "emit.reportBlock('enforce-worktree', 'git commit', 'em1-sid')")"
    out=$(run_with_timeout 10 node -e "$prog" 2>&1)
    check=$(run_with_timeout 5 node -e "
const o = JSON.parse(process.argv[1]);
const f = (o.calls[0]||{}).finding||{};
if (f.severity !== 'error') { console.log('SEV:'+f.severity); process.exit(0); }
console.log('OK');
" "$out" 2>&1)
    [ "$check" = "OK" ] && pass "EM1: reportBlock emits severity:error" \
        || fail "EM1: reportBlock emits severity:error ($check)"
}

# EM2: reportFallback emits severity:"warning"
run_em2() {
    require_source "$EMIT_MODULE" "EM2: reportFallback emits severity:warning" || return
    local prog out check
    prog="$(build_emit_stub "emit.reportFallback('issue-create', 'worktree-notes', 'em2-sid')")"
    out=$(run_with_timeout 10 node -e "$prog" 2>&1)
    check=$(run_with_timeout 5 node -e "
const o = JSON.parse(process.argv[1]);
const f = (o.calls[0]||{}).finding||{};
if (f.severity !== 'warning') { console.log('SEV:'+f.severity); process.exit(0); }
console.log('OK');
" "$out" 2>&1)
    [ "$check" = "OK" ] && pass "EM2: reportFallback emits severity:warning" \
        || fail "EM2: reportFallback emits severity:warning ($check)"
}

run_em1
run_em2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
