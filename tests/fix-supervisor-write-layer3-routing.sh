#!/bin/bash
# tests/fix-supervisor-write-layer3-routing.sh
# Tests: bin/supervisor-write-layer3
# Tags: supervisor, em-supervisor, layer3, fix, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event firing — tests invoke CLI directly, not via hook registration
# - WORKFLOW_SESSION_ID propagation into a live session (Anthropic bug #27987)
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
# RED until bin/supervisor-write-layer3 grows wsid routing
# (resolveWorkflowSessionId + auto-mirror + --mirror-session-id).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-layer3"
CLI_NODE="$_AGENTS_DIR_NODE/bin/supervisor-write-layer3"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Probe: returns 0 (success) when bin/supervisor-write-layer3 already
# references resolveWorkflowSessionId (i.e. wsid routing is wired). When
# absent, SKIP every case in this file.
wsid_routing_wired() {
    grep -q 'resolveWorkflowSessionId' "$CLI"
}

require_wsid_routing() {
    local label="$1"
    if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
        skip "$label (CLI not present)"; return 1
    fi
    if ! wsid_routing_wired; then
        skip "$label (wsid routing not added to supervisor-write-layer3 yet)"; return 1
    fi
    return 0
}

count_state_files() {
    local tmp="$1"
    ls "$tmp"/*-supervisor-state.json 2>/dev/null | wc -l | tr -d ' '
}

read_phase() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.layer3) { process.stdout.write('MISSING'); process.exit(0); }
process.stdout.write(String(st.layer3.l3_phase));
" 2>/dev/null
}

# R1 — explicit --session-id only, no wsid env -> single state file.
run_r1() {
    local label="R1: explicit --session-id only -> single state file written"
    require_wsid_routing "$label" || return
    local tmp count rc
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
        --session-id sid-a --set-audit-phase done >/dev/null 2>&1
    rc=$?
    count=$(count_state_files "$tmp")
    local exists=0
    [ -f "$tmp/sid-a-supervisor-state.json" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$count" = "1" ] && [ $exists -eq 1 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, count=$count, exists=$exists)"
    fi
}

# R2 — no --session-id, no env -> non-zero exit, helpful stderr.
run_r2() {
    local label="R2: no --session-id and no env -> non-zero exit"
    require_wsid_routing "$label" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
        --set-audit-phase done 2>&1)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ] && ( echo "$out" | grep -qiE 'auto-resolve|session-id required' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# R3 — WORKFLOW_SESSION_ID only -> wsid-named state file written.
run_r3() {
    local label="R3: WORKFLOW_SESSION_ID env only -> wsid state file written"
    require_wsid_routing "$label" || return
    local tmp rc exists
    tmp="$(mktemp -d)"
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_SESSION_ID=wsid-r3test \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" --set-audit-phase done >/dev/null 2>&1
    rc=$?
    exists=0
    [ -f "$tmp/wsid-r3test-supervisor-state.json" ] && exists=1
    unset WORKFLOW_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ $exists -eq 1 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, exists=$exists)"
    fi
}

# R4 — both WORKFLOW_SESSION_ID and CLAUDE_SESSION_ID -> auto-mirror writes both.
run_r4() {
    local label="R4: WORKFLOW_SESSION_ID + CLAUDE_SESSION_ID -> auto-mirror both files"
    require_wsid_routing "$label" || return
    local tmp rc wsid_phase cc_phase
    tmp="$(mktemp -d)"
    WORKFLOW_SESSION_ID=wsid-r4 \
        CLAUDE_SESSION_ID=ccu-r4 \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" --set-audit-phase done >/dev/null 2>&1
    rc=$?
    wsid_phase=$(read_phase "$tmp" "wsid-r4")
    cc_phase=$(read_phase "$tmp" "ccu-r4")
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$wsid_phase" = "done" ] && [ "$cc_phase" = "done" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, wsid_phase=$wsid_phase, cc_phase=$cc_phase)"
    fi
}

# R5 — explicit --session-id and --mirror-session-id -> both files written.
run_r5() {
    local label="R5: --session-id + --mirror-session-id -> both files written"
    require_wsid_routing "$label" || return
    local tmp rc x_phase y_phase
    tmp="$(mktemp -d)"
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
        --session-id sid-x --mirror-session-id sid-y --set-audit-phase done >/dev/null 2>&1
    rc=$?
    x_phase=$(read_phase "$tmp" "sid-x")
    y_phase=$(read_phase "$tmp" "sid-y")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$x_phase" = "done" ] && [ "$y_phase" = "done" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, x_phase=$x_phase, y_phase=$y_phase)"
    fi
}

# R6 — increment-l3-retry-count is single-store: env wsid is NOT mirrored.
run_r6() {
    local label="R6: --increment-audit-retry-count is single-store (no wsid mirror)"
    require_wsid_routing "$label" || return
    local tmp out rc count exists_wsid
    tmp="$(mktemp -d)"
    out=$(WORKFLOW_SESSION_ID=wsid-r6 \
        WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" \
            --session-id sid-r6 --increment-audit-retry-count 2>&1)
    rc=$?
    count=$(count_state_files "$tmp")
    exists_wsid=0
    [ -f "$tmp/wsid-r6-supervisor-state.json" ] && exists_wsid=1
    unset WORKFLOW_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 0 ] \
        && [ "$count" = "1" ] \
        && [ $exists_wsid -eq 0 ] \
        && ( echo "$out" | grep -q 'count' ) \
        && ( echo "$out" | grep -q 'frozen' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, count=$count, exists_wsid=$exists_wsid, out=$out)"
    fi
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
