#!/usr/bin/env bash
# tests/feature-supervisor-conv-lang-block.sh
# Tests: hooks/lib/supervisor-report-format.js, hooks/lib/conv-lang.js
# Tags: supervisor, em-supervisor, conv-lang, block-reason, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - CONV_LANG injection in real Claude Code session where env var may not propagate
#   into hook subprocess (Anthropic bug #27987)
# - Real block reason display in live Claude Code session UI
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T3: CONV_LANG=ja → formatCumSevErrorReason with 1 mock finding →
#   (a) returned string STARTS WITH CONV_LANG injection prefix
#   (b) does NOT contain per-finding enumeration line "[1] categories="
# (C4 summary-only assertion)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

FORMAT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js"
CONV_LANG_NODE="$_AGENTS_DIR_NODE/hooks/lib/conv-lang.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

FORMAT_FILE="$AGENTS_DIR/hooks/lib/supervisor-report-format.js"
if [ ! -f "$FORMAT_FILE" ]; then
    skip "T3: supervisor-report-format.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Check conv-lang module exists
CONV_LANG_FILE="$AGENTS_DIR/hooks/lib/conv-lang.js"
if [ ! -f "$CONV_LANG_FILE" ]; then
    skip "T3: conv-lang.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- T3a: CONV_LANG=ja → formatCumSevErrorReason starts with injection prefix ---
run_t3a() {
    local out
    out=$(CONV_LANG=ja run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const { getConvLangInjection } = require('$CONV_LANG_NODE');

const findings = [{
    categories: ['workflow'],
    severity: 'error',
    detail: 'mock detail for T3',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];

const result = fmt.formatCumSevErrorReason(
    findings,
    'test-sid',
    'test-wsid',
    '/agents/agents/supervisor.md',
    '/tmp/state.json',
    'test-sid'
);

const injection = getConvLangInjection();
process.stdout.write(JSON.stringify({ result, injection }));
" 2>/dev/null)

    if [ -z "$out" ]; then
        fail "T3a: node call returned empty output"
        return
    fi

    local injection result
    injection=$(echo "$out" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).injection || '')" 2>/dev/null)
    result=$(echo "$out" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).result || '')" 2>/dev/null)

    if [ -z "$injection" ]; then
        skip "T3a: CONV_LANG=ja getConvLangInjection returned null/empty (may not propagate in env)"
        return
    fi

    # (a) result must START WITH the injection prefix
    if [[ "$result" != "$injection"* ]]; then
        fail "T3a: formatCumSevErrorReason must start with CONV_LANG injection prefix (Change 2 not yet implemented)"
        return
    fi
    pass "T3a: CONV_LANG=ja → result starts with injection prefix"
}

# --- T3b: after Change 2+C4, result must NOT contain per-finding enumeration "[1] categories=" ---
run_t3b() {
    local out
    out=$(CONV_LANG=ja run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const findings = [{
    categories: ['workflow'],
    severity: 'error',
    detail: 'mock detail for T3b',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
const result = fmt.formatCumSevErrorReason(
    findings,
    'test-sid',
    'test-wsid',
    '/agents/agents/supervisor.md',
    '/tmp/state.json',
    'test-sid'
);
process.stdout.write(result);
" 2>/dev/null)

    # C4: per-finding enumeration "[N] categories=" removed; summary line only
    if echo "$out" | grep -qF "[1] categories="; then
        fail "T3b: result must NOT contain per-finding enumeration '[1] categories=' (C4 summary-only not yet implemented)"
        return
    fi
    pass "T3b: no per-finding enumeration line in formatCumSevErrorReason result"
}

# --- T3c: result with CONV_LANG=english → no injection prefix (null → no prefix) ---
run_t3c() {
    local out
    out=$(CONV_LANG=english run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const findings = [{
    categories: ['code'],
    severity: 'error',
    detail: 'english test',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
const result = fmt.formatCumSevErrorReason(
    findings, 'sid', null, '/sup.md', '/st.json', 'sid'
);
// Should start with '[EM Supervisor]' not with a language injection prefix
const startsWithEM = result.startsWith('[EM Supervisor]');
process.stdout.write(startsWithEM ? 'no-prefix' : 'has-prefix');
" 2>/dev/null)

    if [ "$out" = "has-prefix" ]; then
        fail "T3c: CONV_LANG=english should NOT add injection prefix to result"
        return
    fi
    pass "T3c: CONV_LANG=english → no injection prefix added"
}

run_t3a
run_t3b
run_t3c

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
