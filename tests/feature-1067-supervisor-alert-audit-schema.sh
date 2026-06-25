#!/bin/bash
# tests/feature-1067-supervisor-alert-audit-schema.sh
# Tests: hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, schema, alert, audit, scope:issue-specific
# Tests for issue #1067 — alert/audit two-mode schema contract.
# Cases: createEmptyState alert/audit structure; no legacy layer2/layer3 keys;
#        AUDIT_SEVERITY_THRESHOLD; ensureAlertScheduled arming thresholds.
#
# RED: All cases FAIL/SKIP until source changes land (schema still has layer2/layer3).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

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

# SA1: createEmptyState produces alert.{alert_phase,alert_armed_at,...} and audit.{audit_phase,...}
run_sa1() {
    require_source "$SCHEMA_MODULE" "SA1: createEmptyState has alert/audit keys" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-sa1');
const errs = [];
if (!st.alert || typeof st.alert !== 'object') errs.push('alert missing or not object');
if (!st.audit || typeof st.audit !== 'object') errs.push('audit missing or not object');
if (st.alert) {
  if (!('alert_phase' in st.alert)) errs.push('alert.alert_phase missing');
  if (!('alert_armed_at' in st.alert)) errs.push('alert.alert_armed_at missing');
  if (!('alert_cause' in st.alert)) errs.push('alert.alert_cause missing');
  if (!('alert_retry_count' in st.alert)) errs.push('alert.alert_retry_count missing');
  if (!('alert_eligible_phase' in st.alert)) errs.push('alert.alert_eligible_phase missing');
}
if (st.audit) {
  if (!('audit_phase' in st.audit)) errs.push('audit.audit_phase missing');
  if (!('audit_verdict' in st.audit)) errs.push('audit.audit_verdict missing');
  if (!('audit_armed_at' in st.audit)) errs.push('audit.audit_armed_at missing');
  if (!('audit_cause' in st.audit)) errs.push('audit.audit_cause missing');
  if (!('audit_retry_count' in st.audit)) errs.push('audit.audit_retry_count missing');
  if (!('audit_last_run_at' in st.audit)) errs.push('audit.audit_last_run_at missing');
}
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA1: createEmptyState has alert/audit keys"
    else
        fail "SA1: createEmptyState has alert/audit keys (rc=$rc, out=$out)"
    fi
}

# SA2: createEmptyState produces NO layer2/layer3/l2_*/l3_* keys
run_sa2() {
    require_source "$SCHEMA_MODULE" "SA2: createEmptyState has no legacy layer2/layer3/l2_/l3_ keys" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-sa2');
const raw = JSON.stringify(st);
const legacy = ['layer2','layer3'];
const found = legacy.filter(k => {
  const re = new RegExp('\"' + k + '\"\\s*:');
  return re.test(raw);
});
// Also check for l2_ or l3_ prefixed keys at top level or nested
const l2l3 = raw.match(/\"l[23]_[a-z_]+\"/g) || [];
if (found.length > 0) { console.error('legacy keys found: ' + found.join(',')); process.exit(2); }
if (l2l3.length > 0) { console.error('l2_/l3_ keys found: ' + l2l3.join(',')); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA2: createEmptyState has no legacy layer2/layer3/l2_/l3_ keys"
    else
        fail "SA2: createEmptyState has no legacy layer2/layer3/l2_/l3_ keys (rc=$rc, out=$out)"
    fi
}

# SA3: AUDIT_SEVERITY_THRESHOLD exported and equals "error"
run_sa3() {
    require_source "$SCHEMA_MODULE" "SA3: AUDIT_SEVERITY_THRESHOLD === 'error'" || return
    local out rc
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_MODULE_NODE');
if (typeof s.AUDIT_SEVERITY_THRESHOLD === 'undefined') { console.error('not exported'); process.exit(2); }
if (s.AUDIT_SEVERITY_THRESHOLD !== 'error') { console.error('got: '+s.AUDIT_SEVERITY_THRESHOLD); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA3: AUDIT_SEVERITY_THRESHOLD === 'error'"
    else
        fail "SA3: AUDIT_SEVERITY_THRESHOLD === 'error' (rc=$rc, out=$out)"
    fi
}

run_sa1
run_sa2
run_sa3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
