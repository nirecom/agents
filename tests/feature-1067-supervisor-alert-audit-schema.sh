#!/bin/bash
# tests/feature-1067-supervisor-alert-audit-schema.sh
# Tests: hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, schema, alert, audit, scope:issue-specific
# Tests for issue #1067 — alert/audit two-mode schema contract.
# Cases: createEmptyState alert/audit structure; no legacy layer2/layer3 keys;
#        AUDIT_SEVERITY_THRESHOLD; ensureAlertScheduled arming thresholds.
#
# RED: All cases FAIL/SKIP until source changes land (schema still has layer2/layer3).

# L3 gap (what this test does NOT catch):
# - migrateLegacyState interaction with concurrent writes (race between read and atomic rename)
# - validate() rejection surfacing to real Stop-hook callers in a live session
# Closest-to-action mitigation: no supervisor risk category; manual review at WORKFLOW_USER_VERIFIED.

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

# SA4: readStateOrInit migrates legacy layer2/layer3 schema to alert/audit
run_sa4() {
    require_source "$WRITER_MODULE" "SA4: readStateOrInit migrates legacy layer2/layer3 to alert/audit" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4-legacy';
const legacyState = {
  version: 1,
  session_id: sid,
  layer1: { findings: [] },
  layer2: { l2_armed_at: '2026-01-01T00:00:00Z', last_run_at: null, cumulative_severity: 'warning', findings: [{categories:['code'],severity:'warning',detail:'test',timestamp:'2026-01-01T00:00:00.000Z'}], l2_phase: 'pending', l2_cause: null, l2_retry_count: 0, findings_surfaced_at: null, l2_eligible_phase: null },
  layer3: { l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const migrated = w.readStateOrInit(sid);
const errs = [];
if (!migrated.alert || typeof migrated.alert !== 'object') errs.push('alert missing');
if (!migrated.audit || typeof migrated.audit !== 'object') errs.push('audit missing');
if (migrated.layer2 !== undefined) errs.push('layer2 still present');
if (migrated.layer3 !== undefined) errs.push('layer3 still present');
if (migrated.alert && migrated.alert.alert_armed_at !== '2026-01-01T00:00:00Z') errs.push('alert_armed_at not migrated');
if (migrated.alert && migrated.alert.alert_phase !== 'pending') errs.push('alert_phase not migrated');
if (migrated.alert && migrated.alert.cumulative_severity !== 'warning') errs.push('cumulative_severity not migrated');
if (migrated.alert && (!Array.isArray(migrated.alert.findings) || migrated.alert.findings.length !== 1)) errs.push('findings not migrated');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4: readStateOrInit migrates legacy layer2/layer3 to alert/audit"
    else
        fail "SA4: readStateOrInit migrates legacy layer2/layer3 to alert/audit (rc=$rc, out=$out)"
    fi
}

# SA4b: readStateOrInit is idempotent — already-migrated state is not re-processed
run_sa4b() {
    require_source "$WRITER_MODULE" "SA4b: readStateOrInit is idempotent on already-migrated state" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4b-already';
const legacyState = {
  version: 1, session_id: sid, layer1: { findings: [] },
  layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0, findings_surfaced_at: null, l2_eligible_phase: null },
  layer3: { l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
w.readStateOrInit(sid);
const second = w.readStateOrInit(sid);
const errs = [];
if (!second.alert || typeof second.alert !== 'object') errs.push('alert missing on second read');
if (!second.audit || typeof second.audit !== 'object') errs.push('audit missing on second read');
if (second.layer2 !== undefined) errs.push('layer2 present on second read');
if (second.layer3 !== undefined) errs.push('layer3 present on second read');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4b: readStateOrInit is idempotent on already-migrated state"
    else
        fail "SA4b: readStateOrInit is idempotent on already-migrated state (rc=$rc, out=$out)"
    fi
}

# SA4c: readStateOrInit migrates layer2-only legacy state (no layer3 key)
run_sa4c() {
    require_source "$WRITER_MODULE" "SA4c: readStateOrInit migrates layer2-only legacy state" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4c-l2only';
const legacyState = {
  version: 1, session_id: sid, layer1: { findings: [] },
  layer2: { l2_armed_at: '2026-02-01T00:00:00Z', last_run_at: null, cumulative_severity: 'error', findings: [], l2_phase: 'done', l2_cause: 'test', l2_retry_count: 1, findings_surfaced_at: null, l2_eligible_phase: null },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const migrated = w.readStateOrInit(sid);
const errs = [];
if (!migrated.alert || typeof migrated.alert !== 'object') errs.push('alert missing');
if (migrated.layer2 !== undefined) errs.push('layer2 still present');
if (migrated.alert && migrated.alert.alert_armed_at !== '2026-02-01T00:00:00Z') errs.push('alert_armed_at not migrated');
if (migrated.alert && migrated.alert.alert_phase !== 'done') errs.push('alert_phase not migrated');
if (migrated.alert && migrated.alert.alert_cause !== 'test') errs.push('alert_cause not migrated');
if (migrated.alert && migrated.alert.alert_retry_count !== 1) errs.push('alert_retry_count not migrated');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4c: readStateOrInit migrates layer2-only legacy state"
    else
        fail "SA4c: readStateOrInit migrates layer2-only legacy state (rc=$rc, out=$out)"
    fi
}

# SA4d: readStateOrInit migrates layer3-only legacy state (no layer2 key)
run_sa4d() {
    require_source "$WRITER_MODULE" "SA4d: readStateOrInit migrates layer3-only legacy state" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4d-l3only';
const legacyState = {
  version: 1, session_id: sid, layer1: { findings: [] },
  layer3: { l3_phase: 'done', l3_verdict: 'WARN', l3_last_run_at: '2026-03-01T00:00:00Z', l3_armed_at: '2026-03-01T00:00:00Z', l3_cause: 'drift', l3_retry_count: 2, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const migrated = w.readStateOrInit(sid);
const errs = [];
if (!migrated.audit || typeof migrated.audit !== 'object') errs.push('audit missing');
if (migrated.layer3 !== undefined) errs.push('layer3 still present');
if (migrated.audit && migrated.audit.audit_phase !== 'done') errs.push('audit_phase not migrated');
if (migrated.audit && migrated.audit.audit_verdict !== 'WARN') errs.push('audit_verdict not migrated');
if (migrated.audit && migrated.audit.audit_cause !== 'drift') errs.push('audit_cause not migrated');
if (migrated.audit && migrated.audit.audit_retry_count !== 2) errs.push('audit_retry_count not migrated');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4d: readStateOrInit migrates layer3-only legacy state"
    else
        fail "SA4d: readStateOrInit migrates layer3-only legacy state (rc=$rc, out=$out)"
    fi
}

# SA4e: migrated state passes validate()
run_sa4e() {
    require_source "$WRITER_MODULE" "SA4e: migrated state passes validate()" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const s = require('$SCHEMA_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4e-validate';
const legacyState = {
  version: 1, session_id: sid, layer1: { findings: [] },
  layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0, findings_surfaced_at: null, l2_eligible_phase: null },
  layer3: { l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const migrated = w.readStateOrInit(sid);
const vr = s.validate(migrated);
if (!vr.ok) { console.error('validate failed: ' + vr.errors.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4e: migrated state passes validate()"
    else
        fail "SA4e: migrated state passes validate() (rc=$rc, out=$out)"
    fi
}

# SA4f: appendFinding() succeeds end-to-end against a legacy state file
run_sa4f() {
    require_source "$WRITER_MODULE" "SA4f: appendFinding() succeeds on legacy state file" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa4f-e2e';
const legacyState = {
  version: 1, session_id: sid, layer1: { findings: [] },
  layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0, findings_surfaced_at: null, l2_eligible_phase: null },
  layer3: { l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const ok = w.appendFinding(sid, { categories: ['code'], severity: 'warning', detail: 'migration e2e test', reporter: 'sa4f' });
if (!ok) { console.error('appendFinding returned false'); process.exit(2); }
const written = JSON.parse(fs.readFileSync(w.getStatePath(sid), 'utf8'));
if (!written.layer1 || !Array.isArray(written.layer1.findings)) { console.error('layer1.findings missing after write'); process.exit(3); }
if (written.layer1.findings.length !== 1) { console.error('expected 1 finding in layer1, got ' + written.layer1.findings.length); process.exit(4); }
if (written.layer2 !== undefined || written.layer3 !== undefined) { console.error('legacy keys persisted after appendFinding'); process.exit(5); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA4f: appendFinding() succeeds on legacy state file"
    else
        fail "SA4f: appendFinding() succeeds on legacy state file (rc=$rc, out=$out)"
    fi
}

run_sa1
run_sa2
run_sa3
run_sa4
run_sa4b
run_sa4c
run_sa4d
run_sa4e
run_sa4f

# SA5: readStateOrInit returns createEmptyState result when no file exists
run_sa5() {
    require_source "$WRITER_MODULE" "SA5: readStateOrInit returns createEmptyState when no file exists" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const state = w.readStateOrInit('sa5-fresh');
const errs = [];
if (!state.alert || typeof state.alert !== 'object') errs.push('alert missing or not object');
if (!state.audit || typeof state.audit !== 'object') errs.push('audit missing or not object');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA5: readStateOrInit returns createEmptyState when no file exists"
    else
        fail "SA5: readStateOrInit returns createEmptyState when no file exists (rc=$rc, out=$out)"
    fi
}

# SA7: readStateOrInit falls back to createEmptyState on corrupt (non-JSON) file
run_sa7() {
    require_source "$WRITER_MODULE" "SA7: readStateOrInit falls back to createEmptyState on corrupt file" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa7-corrupt';
fs.writeFileSync(w.getStatePath(sid), '{corrupt json');
const state = w.readStateOrInit(sid);
const errs = [];
if (!state.alert || typeof state.alert !== 'object') errs.push('alert missing or not object');
if (!state.audit || typeof state.audit !== 'object') errs.push('audit missing or not object');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA7: readStateOrInit falls back to createEmptyState on corrupt file"
    else
        fail "SA7: readStateOrInit falls back to createEmptyState on corrupt file (rc=$rc, out=$out)"
    fi
}

# SA8: migrateLegacyState backfills created_at and last_updated when absent
run_sa8() {
    require_source "$WRITER_MODULE" "SA8: migrateLegacyState backfills created_at and last_updated when absent" || return
    local out rc tmp
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
const fs = require('fs');
const sid = 'sa8-timestamps';
const legacyState = {
  version: 1,
  session_id: sid,
  layer1: { findings: [] },
  layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0, findings_surfaced_at: null, l2_eligible_phase: null },
  layer3: { l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] },
};
fs.writeFileSync(w.getStatePath(sid), JSON.stringify(legacyState));
const migrated = w.readStateOrInit(sid);
const errs = [];
if (typeof migrated.created_at !== 'string' || !migrated.created_at) errs.push('created_at missing or not string');
if (typeof migrated.last_updated !== 'string' || !migrated.last_updated) errs.push('last_updated missing or not string');
if (errs.length > 0) { console.error(errs.join('; ')); process.exit(2); }
console.log('OK');
" 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "SA8: migrateLegacyState backfills created_at and last_updated when absent"
    else
        fail "SA8: migrateLegacyState backfills created_at and last_updated when absent (rc=$rc, out=$out)"
    fi
}

run_sa5
run_sa7
run_sa8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
