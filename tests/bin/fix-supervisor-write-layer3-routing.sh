#!/bin/bash
# tests/bin/fix-supervisor-write-layer3-routing.sh
# Tests: bin/supervisor-write-audit
# Tags: supervisor, em-supervisor, layer3, fix, scope:issue-specific, transcript-cursor
# L3 gap (what this test does NOT catch):
# - real Claude Code Stop event firing — tests invoke CLI directly, not via hook registration
# - WORKFLOW_SESSION_ID propagation into a live session (Anthropic bug #27987)
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
# RED until bin/supervisor-write-layer3 grows wsid routing
# (resolveWorkflowSessionId + auto-mirror + --mirror-session-id).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

CLI="$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-layer3"
CLI_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/bin/supervisor-write-layer3"
WRITER_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-writer.js"

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
    ls "$tmp"/*.control/supervisor-state.json 2>/dev/null | wc -l | tr -d ' '  # #2434 control file
}

read_phase() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" run_with_timeout 5 node -e "
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
    unset CLAUDE_CODE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
        --session-id sid-a --set-audit-phase done >/dev/null 2>&1
    rc=$?
    count=$(count_state_files "$tmp")
    local exists=0
    [ -f "$tmp/sid-a.control/supervisor-state.json" ] && exists=1
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
    unset CLAUDE_CODE_SESSION_ID || true
    out=$(WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
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
    unset CLAUDE_CODE_SESSION_ID || true
    WORKFLOW_SESSION_ID=wsid-r3test \
        WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" --set-audit-phase done >/dev/null 2>&1
    rc=$?
    exists=0
    [ -f "$tmp/wsid-r3test.control/supervisor-state.json" ] && exists=1
    unset WORKFLOW_SESSION_ID || true
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ $exists -eq 1 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, exists=$exists)"
    fi
}

# R4 — both WORKFLOW_SESSION_ID and CLAUDE_CODE_SESSION_ID -> auto-mirror writes both.
run_r4() {
    local label="R4: WORKFLOW_SESSION_ID + CLAUDE_CODE_SESSION_ID -> auto-mirror both files"
    require_wsid_routing "$label" || return
    local tmp rc wsid_phase cc_phase
    tmp="$(mktemp -d)"
    WORKFLOW_SESSION_ID=wsid-r4 \
        CLAUDE_CODE_SESSION_ID=ccu-r4 \
        WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" --set-audit-phase done >/dev/null 2>&1
    rc=$?
    wsid_phase=$(read_phase "$tmp" "wsid-r4")
    cc_phase=$(read_phase "$tmp" "ccu-r4")
    unset WORKFLOW_SESSION_ID || true
    unset CLAUDE_CODE_SESSION_ID || true
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
    unset CLAUDE_CODE_SESSION_ID || true
    WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
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
        WORKFLOW_PLANS_DIR="$tmp" WORKFLOW_STATE_DIR="$tmp" \
        run_with_timeout 5 node "$CLI_NODE" \
            --session-id sid-r6 --increment-audit-retry-count 2>&1)
    rc=$?
    count=$(count_state_files "$tmp")
    exists_wsid=0
    [ -f "$tmp/wsid-r6.control/supervisor-state.json" ] && exists_wsid=1
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

# --- #2475: --set-transcript-cursor on the audit writer ---------------------
# AUDIT_CLI targets the live bin/supervisor-write-audit (CLI above names the
# retired supervisor-write-layer3 path, so R1-R6 SKIP; that is pre-existing).
AUDIT_CLI="$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit"
AUDIT_CLI_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/bin/supervisor-write-audit"
T_CURSOR_JSON='{"transcript_path":"/t/a.jsonl","line":5,"last_uuid":"u5","updated_at":"2026-01-01T00:00:00Z"}'

read_state_field() {
    local tmp="$1" sid="$2" path="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
let cur = st;
for (const p of '$path'.split('.')) { if (cur == null) break; cur = cur[p]; }
process.stdout.write(JSON.stringify(cur));
" 2>/dev/null
}

# run_audit_cli <plans-dir> <args...> — explicit --session-id, no env ids (no mirror write).
run_audit_cli() {
    local tmp="$1"; shift
    (
        unset WORKFLOW_SESSION_ID CLAUDE_CODE_SESSION_ID
        export WORKFLOW_PLANS_DIR="$tmp"
        run_with_timeout 5 node "$AUDIT_CLI_NODE" "$@"
    )
}

run_t1() {
    local label="T1: audit --set-transcript-cursor alone writes audit.transcript_cursor (alert untouched)"
    [ -f "$AUDIT_CLI" ] || { skip "$label (CLI not present)"; return; }
    local tmp rc line alert count
    tmp="$(mktemp -d)"
    run_audit_cli "$tmp" --session-id t1-sid --set-transcript-cursor "$T_CURSOR_JSON" >/dev/null 2>&1
    rc=$?
    line=$(read_state_field "$tmp" t1-sid "audit.transcript_cursor.line")
    alert=$(read_state_field "$tmp" t1-sid "alert.transcript_cursor")
    count=$(count_state_files "$tmp")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$line" = "5" ] && [ "$alert" = "null" ] && [ "$count" = "1" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, line=$line, alert=$alert, count=$count)"
    fi
}

run_t2() {
    local label="T2: --increment-audit-retry-count + --set-transcript-cursor is mutually exclusive"
    [ -f "$AUDIT_CLI" ] || { skip "$label (CLI not present)"; return; }
    local tmp rc err
    tmp="$(mktemp -d)"
    err=$(run_audit_cli "$tmp" --session-id t2-sid --increment-audit-retry-count --set-transcript-cursor "$T_CURSOR_JSON" 2>&1 >/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 1 ] && printf '%s' "$err" | grep -q 'mutually exclusive'; then
        pass "$label"
    else
        fail "$label (rc=$rc, err=$err)"
    fi
}

# t3_reject <label> <value>: invalid cursor exits 1 and the prior cursor survives.
t3_reject() {
    local label="$1" value="$2" tmp rc before after
    tmp="$(mktemp -d)"
    run_audit_cli "$tmp" --session-id t3-sid --set-transcript-cursor "$T_CURSOR_JSON" >/dev/null 2>&1
    before=$(read_state_field "$tmp" t3-sid "audit.transcript_cursor")
    run_audit_cli "$tmp" --session-id t3-sid --set-transcript-cursor "$value" >/dev/null 2>&1
    rc=$?
    after=$(read_state_field "$tmp" t3-sid "audit.transcript_cursor")
    rm -rf "$tmp"
    if [ $rc -eq 1 ] && [ -n "$before" ] && [ "$before" != "null" ] && [ "$before" = "$after" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, before=$before, after=$after)"
    fi
}

run_t3() {
    [ -f "$AUDIT_CLI" ] || { skip "T3: invalid audit cursor values (CLI not present)"; return; }
    t3_reject "T3a: audit cursor line -1 rejected, state unchanged" \
        '{"transcript_path":"/t/a.jsonl","line":-1,"last_uuid":"u5","updated_at":"2026-01-01T00:00:00Z"}'
    t3_reject "T3b: audit cursor non-JSON rejected, state unchanged" 'not-json'
    t3_reject "T3c: audit cursor non-string last_uuid rejected, state unchanged" \
        '{"transcript_path":"/t/a.jsonl","line":2,"last_uuid":7,"updated_at":"2026-01-01T00:00:00Z"}'
}

run_t4() {
    local label="T4: audit --set-audit-phase after the cursor keeps audit.transcript_cursor"
    [ -f "$AUDIT_CLI" ] || { skip "$label (CLI not present)"; return; }
    local tmp rc line
    tmp="$(mktemp -d)"
    run_audit_cli "$tmp" --session-id t4-sid --set-transcript-cursor "$T_CURSOR_JSON" >/dev/null 2>&1
    run_audit_cli "$tmp" --session-id t4-sid --set-audit-phase in_progress >/dev/null 2>&1
    rc=$?
    line=$(read_state_field "$tmp" t4-sid "audit.transcript_cursor.line")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$line" = "5" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, line=$line)"
    fi
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_t1
run_t2
run_t3
run_t4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
