#!/bin/bash
# tests/fix-supervisor-audit-arm-session-id.sh
# Tests: hooks/supervisor-guard.js, agents/supervisor-audit.md
# Tags: supervisor, em-supervisor, audit, fix, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event firing — tests invoke hook directly, not via hook registration
# - WORKFLOW_SESSION_ID propagation into a live session (Anthropic bug #27987)
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
# RED until the L3-arm block reason gains the three-ID stanza
# (Session ID / Workflow session ID / Effective state session ID) and
# agents/supervisor-layer3.md documents the same triple + auto-resolve guidance.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
AUDIT_AGENT_MD="$AGENTS_DIR/agents/supervisor-audit.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Probes — applied independently per case so static / dynamic gates can
# resolve at different times.
three_id_stanza_present() {
    grep -q 'Workflow session ID:' "$HOOK"
}

t5_guard_removed() {
    ! grep -q 'shouldSkipForSeverity' "$HOOK"
}

require_stanza_runtime() {
    local label="$1"
    if ! three_id_stanza_present; then
        skip "$label (three-ID stanza not yet added to L3-arm block)"; return 1
    fi
    if ! t5_guard_removed; then
        skip "$label (shouldSkipForSeverity guard still present — L3 arm unreachable)"; return 1
    fi
    return 0
}

seed_audit_state_arm() {
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

# Extract the JSON-encoded "reason" value from a single-line hook JSON output
# (`{"decision":"block","reason":"...\n..."}`). Returns the unescaped multi-line
# reason text.
extract_reason() {
    local raw="$1"
    printf '%s' "$raw" | run_with_timeout 5 node -e "
let s = '';
process.stdin.on('data', (c) => { s += c; });
process.stdin.on('end', () => {
  try {
    const obj = JSON.parse(s.split('\n').find((l) => l.trim()) || '{}');
    process.stdout.write(obj.reason || '');
  } catch (_) { process.stdout.write(''); }
});
" 2>/dev/null
}

# T1 — three-ID stanza with CC UUID ≠ wsid (wsid fallback fires).
run_t1() {
    local label="T1: three-ID stanza with CC UUID != wsid"
    require_stanza_runtime "$label" || return
    local tmp out rc reason cc_id wsid_id effective_id
    tmp="$(mktemp -d)"
    # Both files must exist for wsid fallback to fire.
    seed_audit_state_arm "$tmp" "wsid-bbbb" \
        "{ alert_phase: 'done', alert_armed_at: '2026-06-22T10:00:00Z', cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] }"
    seed_audit_state_arm "$tmp" "cc-uuid-aaaa" \
        "{ alert_phase: null, alert_armed_at: null, cumulative_severity: null, findings: [], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] }"
    out=$(CLAUDE_SESSION_ID=cc-uuid-aaaa \
        WORKFLOW_SESSION_ID=wsid-bbbb \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$HOOK" \
        <<< '{"stop_hook_active":false,"session_id":"cc-uuid-aaaa","transcript_path":""}' 2>/dev/null)
    rc=$?
    reason=$(extract_reason "$out")
    cc_id=$(printf '%s' "$reason" | grep -E '^Session ID:' | head -1 | sed 's/^Session ID:[[:space:]]*//')
    wsid_id=$(printf '%s' "$reason" | grep -E '^Workflow session ID:' | head -1 | sed 's/^Workflow session ID:[[:space:]]*//')
    effective_id=$(printf '%s' "$reason" | grep -E '^Effective state session ID:' | head -1 | sed 's/^Effective state session ID:[[:space:]]*//')
    unset CLAUDE_SESSION_ID || true
    unset WORKFLOW_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 2 ] \
        && [ "$cc_id" = "cc-uuid-aaaa" ] \
        && [ "$wsid_id" = "wsid-bbbb" ] \
        && [ "$effective_id" = "wsid-bbbb" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, cc_id=$cc_id, wsid_id=$wsid_id, effective_id=$effective_id, out=$out)"
    fi
}

# T2 — UNAVAILABLE fallback when WORKFLOW_SESSION_ID is unset.
run_t2() {
    local label="T2: three-ID stanza with WORKFLOW_SESSION_ID unset -> UNAVAILABLE"
    require_stanza_runtime "$label" || return
    local tmp out rc reason cc_id wsid_id effective_id
    tmp="$(mktemp -d)"
    seed_audit_state_arm "$tmp" "cc-uuid-aaaa" \
        "{ alert_phase: 'done', alert_armed_at: '2026-06-22T10:00:00Z', cumulative_severity: 'error', findings: [{categories:['workflow'],severity:'error',detail:'test',timestamp:'2026-06-22T10:00:00.000Z'}], alert_retry_count: 0 }" \
        "{ audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null, audit_cause: null, audit_retry_count: 0, findings: [] }"
    unset WORKFLOW_SESSION_ID || true
    out=$(cd "$tmp" && CLAUDE_SESSION_ID=cc-uuid-aaaa \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$HOOK" \
        <<< '{"stop_hook_active":false,"session_id":"cc-uuid-aaaa","transcript_path":""}' 2>/dev/null)
    rc=$?
    reason=$(extract_reason "$out")
    cc_id=$(printf '%s' "$reason" | grep -E '^Session ID:' | head -1 | sed 's/^Session ID:[[:space:]]*//')
    wsid_id=$(printf '%s' "$reason" | grep -E '^Workflow session ID:' | head -1 | sed 's/^Workflow session ID:[[:space:]]*//')
    effective_id=$(printf '%s' "$reason" | grep -E '^Effective state session ID:' | head -1 | sed 's/^Effective state session ID:[[:space:]]*//')
    unset CLAUDE_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 2 ] \
        && [ "$cc_id" = "cc-uuid-aaaa" ] \
        && [ "$wsid_id" = "UNAVAILABLE" ] \
        && [ "$effective_id" = "cc-uuid-aaaa" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, cc_id=$cc_id, wsid_id=$wsid_id, effective_id=$effective_id, out=$out)"
    fi
}

# T3 — static: supervisor-audit.md documents the three-ID stanza.
run_t3() {
    local label="T3: supervisor-audit.md documents 'Effective state session ID' + 'Workflow session ID'"
    if [ ! -f "$AUDIT_AGENT_MD" ]; then
        skip "$label (agents/supervisor-audit.md not present)"; return
    fi
    if ! grep -q 'Effective state session ID' "$AUDIT_AGENT_MD"; then
        skip "$label (Step 5 not done yet — 'Effective state session ID' absent)"; return
    fi
    if ! grep -q 'Workflow session ID' "$AUDIT_AGENT_MD"; then
        skip "$label (Step 5 not done yet — 'Workflow session ID' absent)"; return
    fi
    pass "$label"
}

# T4 — static: supervisor-audit.md mentions 'auto-resolve' guidance.
run_t4() {
    local label="T4: supervisor-audit.md mentions 'auto-resolve' guidance"
    if [ ! -f "$AUDIT_AGENT_MD" ]; then
        skip "$label (agents/supervisor-audit.md not present)"; return
    fi
    if ! grep -q 'auto-resolve' "$AUDIT_AGENT_MD"; then
        skip "$label (Step 5 not done yet — 'auto-resolve' absent)"; return
    fi
    pass "$label"
}

run_t1
run_t2
run_t3
run_t4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
