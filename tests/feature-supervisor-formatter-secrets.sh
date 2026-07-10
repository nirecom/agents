#!/usr/bin/env bash
# tests/feature-supervisor-formatter-secrets.sh
# Tests: hooks/lib/supervisor-report-format.js — secret-leakage prevention for summary-only output
# Tags: supervisor, em-supervisor, formatter, secrets, security, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - The formatter running inside a real Claude Code session block reason displayed to user
# - Unicode / multi-byte secret strings (out of scope for C7)
# - Formatter output being intercepted by intermediate hook layers
# Closest-to-action mitigation: output is rendered only in block-reason strings shown at
# the Claude Code prompt; no persistent storage of formatted output

# C7 [MEDIUM/security]: formatCumSevErrorReason must NOT echo raw finding detail verbatim
# when detail contains sensitive-looking values.
# C7 also covers formatL2ArmedReason and formatWorktreeOffProposalReason with secret-like
# session IDs.
#
# Pre-implementation (C4 summary-only change not yet landed):
#   formatCumSevErrorReason currently DOES print "detail=<verbatim>" per finding.
#   The "detail contains secret" assertions are RED-EXPECTED (fail) until C4 lands.
#   The "summary IS present" assertions are GREEN now (the function already returns output).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

FORMAT_MOD="$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$AGENTS_DIR/hooks/lib/supervisor-report-format.js" ]; then
    skip "C7-all: supervisor-report-format.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

if ! command -v node >/dev/null 2>&1; then
    skip "C7-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

SECRET_DETAIL='api_key=sk-abc123def456 token=ghp_xxxx1234'
SECRET_SESSION='sk-session-abc123'

# --- C7a: formatCumSevErrorReason does NOT echo raw detail verbatim ---
run_c7a() {
    local out rc
    out=$(run_with_timeout 10 node -e "
const f = require('$FORMAT_MOD');
const findings = [{
    categories: ['security'],
    severity: 'error',
    detail: $(node -e "process.stdout.write(JSON.stringify('$SECRET_DETAIL'))"),
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
const result = f.formatCumSevErrorReason(
    findings,
    'test-session-id',
    'test-wsid',
    '/path/to/supervisor.md',
    '/path/to/state.json',
    'test-session-id'
);
process.stdout.write(result);
" 2>/dev/null)
    rc=$?

    if [ $rc -ne 0 ]; then
        fail "C7a: formatCumSevErrorReason threw an error (rc=$rc)"
        return
    fi

    # Assert: summary IS present (finding count and severity indication)
    if echo "$out" | grep -q "cumulative_severity=error\|Alert mode"; then
        pass "C7a: output contains severity/alert summary (summary IS present)"
    else
        fail "C7a: output missing severity/alert summary"
        return
    fi

    # Assert: raw secret detail NOT echoed verbatim (RED-EXPECTED until C4 lands)
    if echo "$out" | grep -qF "$SECRET_DETAIL"; then
        # Current implementation DOES echo the raw detail — RED-EXPECTED
        fail "C7a [RED-EXPECTED]: formatCumSevErrorReason echoes raw detail verbatim (C4 summary-only change not yet implemented)"
    else
        pass "C7a: raw secret detail NOT present in formatted output"
    fi
}

# --- C7b: formatL2ArmedReason with secret-like session ID ---
# Session ID appears in the designated 'Session ID:' field — that is acceptable.
# Assert: session ID does NOT appear embedded in free-form formatted prose OUTSIDE the
# designated field labels (Session ID: / Workflow session ID: / Effective state session ID:).
run_c7b() {
    local out rc
    out=$(run_with_timeout 10 node -e "
const f = require('$FORMAT_MOD');
const result = f.formatL2ArmedReason(
    'C2',
    $(node -e "process.stdout.write(JSON.stringify('$SECRET_SESSION'))"),
    'test-wsid',
    '/path/to/supervisor.md',
    '/path/to/state.json',
    $(node -e "process.stdout.write(JSON.stringify('$SECRET_SESSION'))")
);
process.stdout.write(result);
" 2>/dev/null)
    rc=$?

    if [ $rc -ne 0 ]; then
        fail "C7b: formatL2ArmedReason threw an error (rc=$rc)"
        return
    fi

    # Verify the session ID appears in designated field(s)
    if echo "$out" | grep -q "Session ID:"; then
        pass "C7b: session ID appears in designated 'Session ID:' label field"
    else
        fail "C7b: session ID label 'Session ID:' missing from output"
        return
    fi

    # The session ID may also appear in the one-liner node command (expected, controlled).
    # Count occurrences: if it appears only in label lines and the one-liner, that is acceptable.
    # We assert it does NOT appear in the first non-label lines (alert message line).
    local first_line
    first_line=$(echo "$out" | head -1)
    if echo "$first_line" | grep -qF "$SECRET_SESSION"; then
        fail "C7b: secret-like session ID appears in the alert message line (first line): $first_line"
    else
        pass "C7b: secret-like session ID NOT embedded in alert message line (only in designated fields)"
    fi
}

# --- C7c: formatWorktreeOffProposalReason with secret-like session ID ---
run_c7c() {
    local out rc
    out=$(run_with_timeout 10 node -e "
const f = require('$FORMAT_MOD');
const result = f.formatWorktreeOffProposalReason(
    $(node -e "process.stdout.write(JSON.stringify('$SECRET_SESSION'))"),
    'test-wsid',
    '/path/to/supervisor.md',
    '/path/to/state.json',
    $(node -e "process.stdout.write(JSON.stringify('$SECRET_SESSION'))")
);
process.stdout.write(result);
" 2>/dev/null)
    rc=$?

    if [ $rc -ne 0 ]; then
        fail "C7c: formatWorktreeOffProposalReason threw an error (rc=$rc)"
        return
    fi

    # Verify designated Session ID field is present
    if echo "$out" | grep -q "Session ID:"; then
        pass "C7c: session ID appears in designated 'Session ID:' label field"
    else
        fail "C7c: session ID label 'Session ID:' missing from output"
        return
    fi

    # Assert session ID NOT in the C3 announcement/action line
    local first_line
    first_line=$(echo "$out" | head -1)
    if echo "$first_line" | grep -qF "$SECRET_SESSION"; then
        fail "C7c: secret-like session ID appears in first (announcement) line: $first_line"
    else
        pass "C7c: secret-like session ID NOT embedded in announcement line (only in designated fields)"
    fi
}

run_c7a
run_c7b
run_c7c

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
