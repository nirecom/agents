#!/bin/bash
# tests/feature-883-supervisor-guard-wsid.sh
# Tests: hooks/supervisor-guard.js — dual-identifier (sid + wsid) injection
# Tags: supervisor, em-supervisor, session-id, workflow-state, layer2, hook, stop
# RED for issue #883.
# Verifies that supervisor-guard.js injects both Session ID (CC UUID) and
# Workflow session ID (plan-artifact prefix) into block-reason text, and falls
# back to "UNAVAILABLE" when no same-day context.md exists.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
RESOLVE_WSID_NODE="$_AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"

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
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

require_wsid() {
    local label="$1"
    if ! node -e "const m=require('$RESOLVE_WSID_NODE'); if(typeof m.resolveWorkflowSessionId!=='function') process.exit(1);" 2>/dev/null; then
        skip "$label (resolveWorkflowSessionId not implemented yet)"
        return 1
    fi
    return 0
}

run_g20() {
    require_source "$HOOK" "G20: wsid injected into block-reason when context.md present" || return
    require_wsid "G20: wsid injected into block-reason when context.md present" || return
    local tmp out rc wsid sid TODAY
    tmp="$(mktemp -d)"
    sid="g20-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g20wsid"
    # Priority 1 (WORKTREE_NOTES.md) supplies wsid when running from $tmp.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # Seed supervisor state with next_check_at non-null to trigger branch (3).
    seed_state "$tmp" "$sid" "{ next_check_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Session ID: $sid" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G20: wsid injected into block-reason when context.md present"
    else
        fail "G20: wsid injected into block-reason when context.md present (rc=$rc, out=$out)"
    fi
}

run_g21() {
    require_source "$HOOK" "G21: wsid=UNAVAILABLE when no context.md in plans-dir" || return
    require_wsid "G21: wsid=UNAVAILABLE when no context.md in plans-dir" || return
    local tmp out rc sid
    tmp="$(mktemp -d)"
    sid="g21-sid"
    # No WORKTREE_NOTES.md, no context.md in tmp — resolveWorkflowSessionId returns null -> UNAVAILABLE.
    # Running from $tmp ensures the repo's own WORKTREE_NOTES.md in CWD does not interfere.
    seed_state "$tmp" "$sid" "{ next_check_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "Workflow session ID: UNAVAILABLE"; then
        pass "G21: wsid=UNAVAILABLE when no context.md in plans-dir"
    else
        fail "G21: wsid=UNAVAILABLE when no context.md in plans-dir (rc=$rc, out=$out)"
    fi
}

run_g22() {
    require_source "$HOOK" "G22: cumulative_severity=error path shows Workflow session ID in systemMessage" || return
    require_wsid "G22: cumulative_severity=error path shows Workflow session ID" || return
    local tmp out rc wsid sid TODAY
    tmp="$(mktemp -d)"
    sid="g22-sid"
    TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
    wsid="${TODAY}-g22wsid"
    # Priority 1 (WORKTREE_NOTES.md) supplies wsid when running from $tmp.
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    # cumulative_severity=error triggers branch (2)
    seed_state "$tmp" "$sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'error', findings: [{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"test-finding\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(cd "$tmp" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && echo "$out" | grep -q "systemMessage" && echo "$out" | grep -q "Workflow session ID: $wsid"; then
        pass "G22: cumulative_severity=error path shows Workflow session ID in systemMessage"
    else
        fail "G22: cumulative_severity=error path shows Workflow session ID in systemMessage (rc=$rc, out=$out)"
    fi
}

run_g20
run_g21
run_g22

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
