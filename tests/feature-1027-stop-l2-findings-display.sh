#!/bin/bash
# tests/feature-1027-stop-l2-findings-display.sh
# Tests: hooks/stop-l2-findings-display.js, hooks/lib/supervisor-findings-render.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 — Stop hook stop-l2-findings-display.js (NEW).
#
# # L3 gap
# L2 invokes the hook via direct node + stdin JSON. L3 (live Stop event under
# `claude -p`) is required to validate registration in settings.json and
# verify that additionalContext is delivered to the agent loop.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/stop-l2-findings-display.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/stop-l2-findings-display.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

seed_state() {
    local tmp="$1" sid="$2" alert_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert = Object.assign(st.alert || {}, $alert_json);
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_alert_field() {
    local tmp="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st) { process.exit(2); }
const v = st.alert['$field'];
if (v === null) console.log('NULL'); else console.log(String(v));
" 2>/dev/null
}

# --- D1: state file absent -> exit 0 silent ---------------------------------
run_d1() {
    require_source "$HOOK" "D1: state file absent -> exit 0 silent" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{"stop_hook_active":false,"session_id":"d1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "D1: state file absent -> exit 0 silent"
    else
        fail "D1: state absent (rc=$rc, out=$out)"
    fi
}

# --- D2: findings_surfaced_at already set -> exit 0 silent (no output) ------
run_d2() {
    require_source "$HOOK" "D2: findings_surfaced_at already set -> exit 0 silent" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d2-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: '2026-06-21T02:00:00Z', findings: [{ categories:['code'], severity:'warning', detail:'x', reporter:'r', timestamp:'2026-06-21T01:00:00Z' }] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] || ! ( echo "$out" | grep -qi "additionalContext" ) ); then
        pass "D2: findings_surfaced_at already set -> no additionalContext"
    else
        fail "D2: surfaced gate (rc=$rc, out=$out)"
    fi
}

# --- D3: pending + last_run_at=null -> exit 0 silent (no completed L2) ------
run_d3() {
    require_source "$HOOK" "D3: pending + last_run_at null -> exit 0 silent" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d3-sid" "{ alert_phase: 'pending', last_run_at: null, findings_surfaced_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d3-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "additionalContext" ); then
        pass "D3: pending + last_run_at null -> no additionalContext"
    else
        fail "D3: pending+null last_run_at (rc=$rc, out=$out)"
    fi
}

# --- D4 (Fire A): l2_phase=done + 1 warning finding -> additionalContext + marks surfaced ---
run_d4() {
    require_source "$HOOK" "D4: done + warning -> additionalContext + marks surfaced" || return
    local tmp out rc surfaced
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d4-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'warn1', reporter:'rep1', timestamp:'2026-06-21T01:00:00Z' }] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d4-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    surfaced="$(read_alert_field "$tmp" "d4-sid" "findings_surfaced_at")"
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "additionalContext" && [ "$surfaced" != "NULL" ] && [ -n "$surfaced" ]; then
        pass "D4 (Fire A): done + warning -> additionalContext + findings_surfaced_at set"
    else
        fail "D4: done+warning (rc=$rc, surfaced=$surfaced, out=$out)"
    fi
}

# --- D5 (Fire B): pending + last_run_at set (#961 state) -> additionalContext + marks surfaced ---
run_d5() {
    require_source "$HOOK" "D5: pending + last_run_at set -> additionalContext + marks surfaced" || return
    local tmp out rc surfaced
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d5-sid" "{ alert_phase: 'pending', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'warnB', reporter:'rep', timestamp:'2026-06-21T01:00:00Z' }] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d5-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    surfaced="$(read_alert_field "$tmp" "d5-sid" "findings_surfaced_at")"
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "additionalContext" && [ "$surfaced" != "NULL" ] && [ -n "$surfaced" ]; then
        pass "D5 (Fire B): pending + last_run_at set -> additionalContext + findings_surfaced_at set"
    else
        fail "D5: pending+last_run_at (rc=$rc, surfaced=$surfaced, out=$out)"
    fi
}

# --- D6 (Fire C): dual-ID fallback — session_id missing, wsid resolves state -
run_d6() {
    require_source "$HOOK" "D6: dual-ID fallback via workflowSessionId" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # Seed state at WSID
    seed_state "$tmp" "d6-wsid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'wd6', reporter:'r', timestamp:'2026-06-21T01:00:00Z' }] }"
    # Invoke with a different session_id, but provide WORKFLOW_SESSION_ID env so
    # the hook can resolve the wsid path.
    out=$(echo '{"stop_hook_active":false,"session_id":"d6-sid-different","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_SESSION_ID="d6-wsid" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "additionalContext"; then
        pass "D6 (Fire C): dual-ID fallback resolves state via wsid"
    else
        fail "D6: dual-ID fallback (rc=$rc, out=$out)"
    fi
}

# --- D7: idempotency — second invocation exits silent -----------------------
run_d7() {
    require_source "$HOOK" "D7: idempotency — second invocation silent" || return
    local tmp out1 out2 rc1 rc2
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d7-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'w7', reporter:'r', timestamp:'2026-06-21T01:00:00Z' }] }"
    out1=$(echo '{"stop_hook_active":false,"session_id":"d7-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc1=$?
    out2=$(echo '{"stop_hook_active":false,"session_id":"d7-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc2=$?
    rm -rf "$tmp"
    if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && \
       echo "$out1" | grep -qi "additionalContext" && \
       ! echo "$out2" | grep -qi "additionalContext"; then
        pass "D7: first invocation surfaces; second invocation silent"
    else
        fail "D7: idempotency (rc1=$rc1, rc2=$rc2, out1=$out1, out2=$out2)"
    fi
}

# --- D8: stop_hook_active=true -> exit 0 silent -----------------------------
run_d8() {
    require_source "$HOOK" "D8: stop_hook_active=true -> exit 0 silent" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d8-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'w8', reporter:'r', timestamp:'2026-06-21T01:00:00Z' }] }"
    out=$(echo '{"stop_hook_active":true,"session_id":"d8-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "additionalContext"; then
        pass "D8: stop_hook_active=true -> no additionalContext"
    else
        fail "D8: stop_hook_active gate (rc=$rc, out=$out)"
    fi
}

# --- D9: hook NEVER emits "decision" key on any code path --------------------
run_d9() {
    require_source "$HOOK" "D9: hook never emits decision key" || return
    local tmp out_all rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d9-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'error', detail:'errD9', reporter:'r', timestamp:'2026-06-21T01:00:00Z' }] }"
    # Fire path
    out_all=$(echo '{"stop_hook_active":false,"session_id":"d9-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    # Gate path (already surfaced)
    out_all="${out_all}|$(echo '{"stop_hook_active":false,"session_id":"d9-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)"
    rm -rf "$tmp"
    if ! echo "$out_all" | grep -q '"decision"'; then
        pass "D9: hook never emits 'decision' key"
    else
        fail "D9: hook emitted decision key (out=$out_all)"
    fi
}

# --- D10 (Fire D): l2_phase=frozen + warning finding -> additionalContext + marks surfaced ---
run_d10() {
    require_source "$HOOK" "D10: frozen + warning -> additionalContext + marks surfaced" || return
    local tmp out rc surfaced
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d10-sid" "{ alert_phase: 'frozen', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [{ categories:['code'], severity:'warning', detail:'warn-frozen', reporter:'rep', timestamp:'2026-06-21T01:00:00Z' }] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d10-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    surfaced="$(read_alert_field "$tmp" "d10-sid" "findings_surfaced_at")"
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "additionalContext" && [ "$surfaced" != "NULL" ] && [ -n "$surfaced" ]; then
        pass "D10 (Fire D): frozen + warning -> additionalContext + findings_surfaced_at set"
    else
        fail "D10: frozen+warning (rc=$rc, surfaced=$surfaced, out=$out)"
    fi
}

# --- D11: l2_phase=done + findings=[] -> exit 0 silent ----------------------
run_d11() {
    require_source "$HOOK" "D11: done + empty findings -> exit 0 silent" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "d11-sid" "{ alert_phase: 'done', last_run_at: '2026-06-21T01:00:00Z', findings_surfaced_at: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"d11-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] || ! echo "$out" | grep -qi "additionalContext" ); then
        pass "D11: done + empty findings -> no additionalContext"
    else
        fail "D11: done+empty findings (rc=$rc, out=$out)"
    fi
}

run_d1
run_d2
run_d3
run_d4
run_d5
run_d6
run_d7
run_d8
run_d9
run_d10
run_d11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
