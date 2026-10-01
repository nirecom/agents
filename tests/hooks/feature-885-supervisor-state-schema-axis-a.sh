#!/bin/bash
# tests/hooks/feature-885-supervisor-state-schema-axis-a.sh
# Tests: hooks/lib/supervisor-state-schema.js
# Tags: supervisor-state-schema, finding-schema, axis-a, feature-885, scope:issue-specific, transcript-cursor
# Tests for issue #885 — Axis A finding schema extension.
#
# Verifies validateFinding accepts the new optional fields (reason, context,
# co_blocked_by) and rejects malformed values. The existing whitelist-allow
# behavior must be preserved: unknown fields pass; the new fields are validated
# only when present.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

# expect_valid <label> <finding-json>
expect_valid() {
    local label="$1" finding="$2"
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const f = $finding;
const r = s.validateFinding(f);
if (r.ok !== true) { console.error('expected ok=true, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# expect_invalid <label> <finding-json>
expect_invalid() {
    local label="$1" finding="$2"
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const f = $finding;
const r = s.validateFinding(f);
if (r.ok !== false) { console.error('expected ok=false, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

if [ ! -f "$SCHEMA_MODULE" ]; then
    skip "supervisor-state-schema.js not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- A1: existing minimal finding (no new fields) still valid ----------------
expect_valid "A1: existing minimal finding (no new fields) valid" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r' }"

# --- A2: finding with all 3 new fields fully populated -----------------------
expect_valid "A2: finding with reason+context+co_blocked_by valid" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r',
  reason: 'cwd_no_git_root',
  context: { cwd: '/tmp/x', git_root_resolved: false },
  co_blocked_by: ['enforce-issue-close'] }"

# --- A3: reason as number -> invalid -----------------------------------------
expect_invalid "A3: reason as number rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', reason: 42 }"

# --- A4: reason as empty string -> invalid -----------------------------------
expect_invalid "A4: reason empty string rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', reason: '' }"

# --- A5: reason as single char -> valid --------------------------------------
expect_valid "A5: reason single-char valid" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', reason: 'x' }"

# --- A6: context as array -> invalid -----------------------------------------
expect_invalid "A6: context as array rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', context: ['nope'] }"

# --- A7: context.cwd as number -> invalid ------------------------------------
expect_invalid "A7: context.cwd as number rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', context: { cwd: 1 } }"

# --- A8: context.git_root_resolved as string -> invalid ----------------------
expect_invalid "A8: context.git_root_resolved as string rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', context: { git_root_resolved: 'true' } }"

# --- A9: co_blocked_by as string (not array) -> invalid ----------------------
expect_invalid "A9: co_blocked_by as string rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', co_blocked_by: 'enforce-issue-close' }"

# --- A10: co_blocked_by contains non-string -> invalid -----------------------
expect_invalid "A10: co_blocked_by with non-string element rejected" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', co_blocked_by: ['ok', 42] }"

# --- A11: co_blocked_by empty array -> valid (key present, empty) ------------
expect_valid "A11: co_blocked_by empty array valid" \
"{ categories: ['workflow'], severity: 'warning', detail: 'd', reporter: 'r', co_blocked_by: [] }"

# --- #2475: transcript_cursor on alert/audit ---------------------------------
# expect_cursor <label> <cursor-js-literal> <want ok: true|false>
expect_cursor() {
    local label="$1" cursor="$2" want="$3"
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
if (typeof s.validateTranscriptCursor !== 'function') { console.error('validateTranscriptCursor not exported'); process.exit(2); }
const r = s.validateTranscriptCursor($cursor);
if (!r || r.ok !== $want) { console.error('expected ok=$want, got: '+JSON.stringify(r)); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

GOOD_CURSOR="{ transcript_path: '/t/a.jsonl', line: 5, last_uuid: 'u5', updated_at: '2026-01-01T00:00:00Z' }"

expect_cursor "TC1: validateTranscriptCursor accepts null" "null" "true"
expect_cursor "TC2: validateTranscriptCursor accepts a well-formed cursor" "$GOOD_CURSOR" "true"
expect_cursor "TC3: validateTranscriptCursor accepts last_uuid null" \
"{ transcript_path: '/t/a.jsonl', line: 0, last_uuid: null, updated_at: '2026-01-01T00:00:00Z' }" "true"
expect_cursor "TC4: negative line rejected" \
"{ transcript_path: '/t/a.jsonl', line: -1, last_uuid: 'u5', updated_at: '2026-01-01T00:00:00Z' }" "false"
expect_cursor "TC5: non-integer line rejected" \
"{ transcript_path: '/t/a.jsonl', line: 1.5, last_uuid: 'u5', updated_at: '2026-01-01T00:00:00Z' }" "false"
expect_cursor "TC6: empty transcript_path rejected" \
"{ transcript_path: '', line: 5, last_uuid: 'u5', updated_at: '2026-01-01T00:00:00Z' }" "false"
expect_cursor "TC7: non-string last_uuid rejected" \
"{ transcript_path: '/t/a.jsonl', line: 5, last_uuid: 5, updated_at: '2026-01-01T00:00:00Z' }" "false"
expect_cursor "TC8: empty updated_at rejected" \
"{ transcript_path: '/t/a.jsonl', line: 5, last_uuid: 'u5', updated_at: '' }" "false"
expect_cursor "TC9: string line rejected" \
"{ transcript_path: '/t/a.jsonl', line: '5', last_uuid: 'u5', updated_at: '2026-01-01T00:00:00Z' }" "false"

# TC10/TC11: createEmptyState seeds both cursors null; validate() rejects a bad one.
tc_out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('s');
const a = st.alert && Object.prototype.hasOwnProperty.call(st.alert, 'transcript_cursor') ? st.alert.transcript_cursor : 'missing';
const u = st.audit && Object.prototype.hasOwnProperty.call(st.audit, 'transcript_cursor') ? st.audit.transcript_cursor : 'missing';
const base = s.validate(st);
const bad = s.createEmptyState('s'); bad.alert.transcript_cursor = { transcript_path: '/t', line: -1, last_uuid: null, updated_at: 'x' };
const badAudit = s.createEmptyState('s'); badAudit.audit.transcript_cursor = { transcript_path: '', line: 1, last_uuid: null, updated_at: 'x' };
const good = s.createEmptyState('s'); good.alert.transcript_cursor = $GOOD_CURSOR;
console.log([a === null, u === null, base.ok === true, s.validate(bad).ok === false, s.validate(badAudit).ok === false, s.validate(good).ok === true].join(','));
" 2>&1)
if [ "$tc_out" = "true,true,true,true,true,true" ]; then
    pass "TC10: createEmptyState seeds alert/audit transcript_cursor null; validate() checks both cursors"
else
    fail "TC10: createEmptyState/validate transcript_cursor contract (got: $tc_out; want all true: alertNull,auditNull,emptyValid,badAlertRejected,badAuditRejected,goodAccepted)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
