# tests/feature-719-supervisor-guard-hook/g-audit-phase-b.sh
# G-B1..G-B5: Phase B arbitration wiring (#1043).
# Probes whether arbitrate() is wired into the L3 Phase B branch of
# supervisor-guard.js. SKIP all cases until the wiring lands.

# Probe: returns "yes" when supervisor-guard.js requires arbitrate (i.e. Phase B
# arbitration is wired into the hook). The check is a simple grep on the hook
# source for "arbitrate" so it is robust to both
# `require("./lib/supervisor-guard/arbitrate")` and `require(".../arbitrate.js")`
# spellings.
require_phase_b_arbitrate() {
    local label="$1"
    if grep -q 'arbitrate' "$HOOK"; then
        return 0
    fi
    skip "$label (Phase B arbitration not wired yet)"; return 1
}

# Seed BOTH alert and audit of the state file.
seed_audit_state() {
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

# Read a dotted path from audit of the state file post-invocation.
# Usage: read_audit_field <tmp> <sid> <field>
# Prints raw value (null becomes the literal string 'null').
read_audit_field() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.audit) { process.stdout.write('MISSING'); process.exit(0); }
const v = st.audit['$field'];
process.stdout.write(v === null ? 'null' : (v === undefined ? 'undefined' : String(v)));
" 2>/dev/null
}

read_l2_field() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.alert) { process.stdout.write('MISSING'); process.exit(0); }
const v = st.alert['$field'];
process.stdout.write(v === null ? 'null' : (v === undefined ? 'undefined' : String(v)));
" 2>/dev/null
}

# G-B1 — audit done + WARN + alert clean -> exit 0, additionalContext present, audit_phase cleared.
run_g_b1() {
    local label="G-B1: audit done+WARN + alert clean -> additionalContext, audit_phase cleared"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc audit_phase_after
    tmp="$(mktemp -d)"
    seed_audit_state "$tmp" "g-b1-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'WARN', audit_cause: 'cross-stage drift', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-b1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase_after=$(read_audit_field "$tmp" "g-b1-sid" "audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -q '"additionalContext"' ) && [ "$audit_phase_after" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase_after=$audit_phase_after, out=$out)"
    fi
}

# G-B2 — audit done + BLOCK + alert clean -> rc=2, decision:block.
run_g_b2() {
    local label="G-B2: audit done+BLOCK + alert clean -> decision:block, exit 2"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_audit_state "$tmp" "g-b2-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'BLOCK', audit_cause: 'strategic block', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-b2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q '"decision":"block"' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# G-B3 — audit done + CONTINUE + alert clean -> rc=0, no additionalContext, audit_phase cleared.
run_g_b3() {
    local label="G-B3: audit done+CONTINUE + alert clean -> silent exit 0, audit_phase cleared"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc audit_phase_after
    tmp="$(mktemp -d)"
    seed_audit_state "$tmp" "g-b3-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'CONTINUE', audit_cause: 'no concern', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-b3-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase_after=$(read_audit_field "$tmp" "g-b3-sid" "audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -q '"additionalContext"' ) && [ "$audit_phase_after" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase_after=$audit_phase_after, out=$out)"
    fi
}

# G-B4 — audit done + BLOCK + alert cumSev=error (alert_phase=pending) -> rc=2 block,
# and tryIncrementFrozen must NOT be called for the both-source block path:
# alert_retry_count stays 0.
run_g_b4() {
    local label="G-B4: audit done+BLOCK + alert cumSev=error -> block, alert_retry_count not incremented"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc alert_retry_after
    tmp="$(mktemp -d)"
    seed_audit_state "$tmp" "g-b4-sid" \
        "{ alert_phase: 'pending', alert_armed_at: null, cumulative_severity: 'error', findings: [], alert_retry_count: 0 }" \
        "{ audit_phase: 'done', audit_verdict: 'BLOCK', audit_cause: 'strategic block', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g-b4-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    alert_retry_after=$(read_l2_field "$tmp" "g-b4-sid" "alert_retry_count")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q '"decision":"block"' ) && [ "$alert_retry_after" = "0" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, alert_retry_after=$alert_retry_after, out=$out)"
    fi
}

# G-B6 — dual-store: wsid and CC UUID each have audit_phase=done; Phase B must clear both.
run_g_b6() {
    local label="G-B6: dual-store Phase B clears audit_phase in both wsid and CC-UUID stores"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc wsid_phase_after cc_phase_after
    tmp="$(mktemp -d)"
    # wsid store: alert_armed_at set (triggers effective-store fallback to wsid); alert_phase=done
    # so branch (3) is guarded away and Phase B WARN can surface as additionalContext.
    seed_audit_state "$tmp" "wsid-g-b6" \
        "{ alert_phase: 'done', alert_armed_at: '2026-06-22T10:00:00Z', cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'WARN', audit_cause: 'cross-stage drift', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    # CC UUID store: no alert_armed_at; audit_phase=done (mirror written by writer).
    seed_audit_state "$tmp" "cc-g-b6" \
        "{ alert_phase: null, alert_armed_at: null, cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'WARN', audit_cause: 'cross-stage drift', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(WORKFLOW_SESSION_ID=wsid-g-b6 \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$HOOK" \
        <<< '{"stop_hook_active":false,"session_id":"cc-g-b6","transcript_path":""}' 2>/dev/null)
    rc=$?
    wsid_phase_after=$(read_audit_field "$tmp" "wsid-g-b6" "audit_phase")
    cc_phase_after=$(read_audit_field "$tmp" "cc-g-b6" "audit_phase")
    unset WORKFLOW_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 0 ] \
        && ( echo "$out" | grep -q '"additionalContext"' ) \
        && [ "$wsid_phase_after" = "null" ] \
        && [ "$cc_phase_after" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, wsid_phase=$wsid_phase_after, cc_phase=$cc_phase_after, out=$out)"
    fi
}

# G-B5 — audit done + WARN + C3 worktreeOffProposal present -> rc=2 block (C3 wins),
# audit_phase still cleared.
run_g_b5() {
    local label="G-B5: audit done+WARN + C3 OFF proposal -> block (C3 wins), audit_phase cleared"
    require_source "$HOOK" "$label" || return
    require_phase_b_arbitrate "$label" || return
    local tmp out rc tp audit_phase_after
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"q"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_audit_state "$tmp" "g-b5-sid" \
        "{ alert_phase: 'done', alert_armed_at: null, cumulative_severity: null, findings: [] }" \
        "{ audit_phase: 'done', audit_verdict: 'WARN', audit_cause: 'cross-stage drift', audit_retry_count: 0, audit_last_run_at: null, audit_armed_at: null, findings: [] }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g-b5-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    audit_phase_after=$(read_audit_field "$tmp" "g-b5-sid" "audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q '"decision":"block"' ) && [ "$audit_phase_after" = "null" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, audit_phase_after=$audit_phase_after, out=$out)"
    fi
}
