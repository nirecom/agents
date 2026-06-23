# tests/feature-719-supervisor-guard-hook/g-l3-t5-arm.sh
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

# G-T5 cases share the seed_l3_state helper from g-l3-phase-b.sh, but case
# files are sourced independently. Define a local copy so this file is
# self-contained (and works whether or not g-l3-phase-b.sh has been sourced).
seed_l3_state_t5() {
    local tmp="$1" sid="$2" layer2_json="$3" layer3_json="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = Object.assign({}, st.layer2, $layer2_json);
st.layer3 = Object.assign({}, st.layer3, $layer3_json);
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_l3_field_t5() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.layer3) { process.stdout.write('MISSING'); process.exit(0); }
const v = st.layer3['$field'];
process.stdout.write(v === null ? 'null' : (v === undefined ? 'undefined' : String(v)));
" 2>/dev/null
}

# G-T5-1 — cumSev=error, l2_phase=done, fresh L3 state -> L3 arms (block, l3_phase=pending).
run_g_t5_1() {
    local label="G-T5-1: cumSev=error + l2_phase=done + fresh L3 -> arm L3 (block)"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc l3_phase l3_armed_at l3_cause
    tmp="$(mktemp -d)"
    seed_l3_state_t5 "$tmp" "g-t5-1-sid" \
        "{ l2_phase: 'done', l2_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], l2_retry_count: 0 }" \
        "{ l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    l3_phase=$(read_l3_field_t5 "$tmp" "g-t5-1-sid" "l3_phase")
    l3_armed_at=$(read_l3_field_t5 "$tmp" "g-t5-1-sid" "l3_armed_at")
    l3_cause=$(read_l3_field_t5 "$tmp" "g-t5-1-sid" "l3_cause")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] \
        && ( echo "$out" | grep -q '"decision":"block"' ) \
        && ( echo "$out" | grep -q 'Layer 3 strategic review triggered' ) \
        && ( echo "$out" | grep -q 'severity-threshold:error' ) \
        && [ "$l3_phase" = "pending" ] \
        && [ "$l3_armed_at" != "null" ] && [ "$l3_armed_at" != "MISSING" ] \
        && [ "$l3_cause" = "severity-threshold:error" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_phase=$l3_phase, l3_armed_at=$l3_armed_at, l3_cause=$l3_cause, out=$out)"
    fi
}

# G-T5-2 — same seed as G-T5-1 BUT layer3.l3_last_run_at set and l3_cause matches
# (dedup guard fires) -> NOT armed.
run_g_t5_2() {
    local label="G-T5-2: dedup guard fires -> NOT armed, l3_phase stays null"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc l3_phase
    tmp="$(mktemp -d)"
    seed_l3_state_t5 "$tmp" "g-t5-2-sid" \
        "{ l2_phase: 'done', l2_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], l2_retry_count: 0 }" \
        "{ l3_phase: null, l3_verdict: null, l3_last_run_at: '2026-06-22T10:00:00Z', l3_armed_at: null, l3_cause: 'severity-threshold:error', l3_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    l3_phase=$(read_l3_field_t5 "$tmp" "g-t5-2-sid" "l3_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$l3_phase" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_phase=$l3_phase, out=$out)"
    fi
}

# G-T5-3 — cumSev=error + l2_phase=frozen -> same arm behavior as G-T5-1.
run_g_t5_3() {
    local label="G-T5-3: cumSev=error + l2_phase=frozen + fresh L3 -> arm L3 (block)"
    require_source "$HOOK" "$label" || return
    require_t5_guard_removed "$label" || return
    local tmp out rc l3_phase
    tmp="$(mktemp -d)"
    seed_l3_state_t5 "$tmp" "g-t5-3-sid" \
        "{ l2_phase: 'frozen', l2_armed_at: null, cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], l2_retry_count: 0 }" \
        "{ l3_phase: null, l3_verdict: null, l3_last_run_at: null, l3_armed_at: null, l3_cause: null, l3_retry_count: 0, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-t5-3-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    l3_phase=$(read_l3_field_t5 "$tmp" "g-t5-3-sid" "l3_phase")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q '"decision":"block"' ) && [ "$l3_phase" = "pending" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, l3_phase=$l3_phase, out=$out)"
    fi
}
