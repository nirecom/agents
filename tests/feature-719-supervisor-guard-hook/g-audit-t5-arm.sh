# tests/feature-719-supervisor-guard-hook/g-audit-t5-arm.sh
# G-T5-1..G-T5-3: T5 — Phase A L3 arming via severity-threshold (#1044).
# Probes whether the shouldSkipForSeverity guard has been removed from
# supervisor-guard.js. When the guard is still present, T5 paths are
# unreachable (cumSev=error + l2_phase=done|frozen short-circuit) so SKIP.

require_t5_guard_removed() {
    local label="$1"
    if grep -q 'shouldSkipForSeverity' "$HOOK"; then
        skip "$label (shouldSkipForSeverity guard still present — T5 unreachable)"; return 1
    fi
    return 0
}

# G-T5 cases share the seed_audit_state helper from g-audit-phase-b.sh, but case
# files are sourced independently. Define a local copy so this file is
# self-contained (and works whether or not g-audit-phase-b.sh has been sourced).
seed_audit_state_t5() {
    local tmp="$1" sid="$2" layer2_json="$3" layer3_json="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert = Object.assign({}, st.alert, $layer2_json);
st.audit = Object.assign({}, st.audit, $layer3_json);
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_audit_field_t5() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.audit) { process.stdout.write('MISSING'); process.exit(0); }
const v = st.audit['$field'];
process.stdout.write(v === null ? 'null' : (v === undefined ? 'undefined' : String(v)));
" 2>/dev/null
}

# G-T5-1 — cumSev=error, alert_phase=done, fresh audit state -> audit arms (block, audit_phase=pending).
run_g_t5_1() {
    local label="G-T5-1: cumSev=error + alert_phase=done + fresh audit -> arm audit (block)"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc audit_phase audit_armed_at audit_cause
    tmp="$(mktemp -d)"
    seed_audit_state_t5 "$tmp" "g-t5-1-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase=$(read_audit_field_t5 "$tmp" "g-t5-1-sid" "audit_phase")
    audit_armed_at=$(read_audit_field_t5 "$tmp" "g-t5-1-sid" "audit_armed_at")
    audit_cause=$(read_audit_field_t5 "$tmp" "g-t5-1-sid" "audit_cause")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] \
        && ( echo "$out" | grep -q '"decision":"block"' ) \
        && ( echo "$out" | grep -q 'Audit mode strategic review triggered' ) \
        && ( echo "$out" | grep -q 'severity-threshold:error' ) \
        && [ "$audit_phase" = "pending" ] \
        && [ "$audit_armed_at" != "null" ] && [ "$audit_armed_at" != "MISSING" ] \
        && [ "$audit_cause" = "severity-threshold:error" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase=$audit_phase, audit_armed_at=$audit_armed_at, audit_cause=$audit_cause, out=$out)"
    fi
}

# G-T5-2 — same seed as G-T5-1 BUT audit.audit_last_run_at set and audit_cause matches
# (dedup guard fires) -> NOT armed.
run_g_t5_2() {
    local label="G-T5-2: dedup guard fires -> NOT armed, audit_phase stays null"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc audit_phase
    tmp="$(mktemp -d)"
    seed_audit_state_t5 "$tmp" "g-t5-2-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: '2026-06-22T10:00:00Z', audit_armed_at: null, audit_cause: 'severity-threshold:error', audit_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase=$(read_audit_field_t5 "$tmp" "g-t5-2-sid" "audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$audit_phase" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase=$audit_phase, out=$out)"
    fi
}

# G-T5-3 — cumSev=error + alert_phase=frozen -> same arm behavior as G-T5-1.
run_g_t5_3() {
    local label="G-T5-3: cumSev=error + alert_phase=frozen + fresh audit -> arm audit (block)"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc audit_phase
    tmp="$(mktemp -d)"
    seed_audit_state_t5 "$tmp" "g-t5-3-sid" \
        "{ alert_phase: 'frozen', alert_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-3-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase=$(read_audit_field_t5 "$tmp" "g-t5-3-sid" "audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q '"decision":"block"' ) && [ "$audit_phase" = "pending" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase=$audit_phase, out=$out)"
    fi
}
