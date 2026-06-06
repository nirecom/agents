#!/bin/bash
# tests/feature-719-supervisor-guard-hook.sh
# Tests: hooks/supervisor-guard.js (Stop hook — wakeup reader / block-on-error)
# Tags: supervisor, em-supervisor, hook, layer2, stop
# RED for issue #719.

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

run_g1() {
    require_source "$HOOK" "G1: next_check_at non-null -> additionalContext mentions supervisor.md" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g1-sid" "{ next_check_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g1-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qi "supervisor.md" ) && ( echo "$out" | grep -qi "agents" ); then
        pass "G1: next_check_at non-null -> additionalContext mentions supervisor.md"
    else
        fail "G1: next_check_at non-null -> additionalContext mentions supervisor.md (rc=$rc, out=$out)"
    fi
}

run_g2() {
    require_source "$HOOK" "G2: cumulative_severity=error -> decision=block, exit 2" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g2-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g2-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ) && ( echo "$out" | grep -qi "systemMessage" ); then
        pass "G2: cumulative_severity=error -> decision=block + systemMessage, exit 2"
    else
        fail "G2: cumulative_severity=error -> decision=block + systemMessage, exit 2 (rc=$rc, out=$out)"
    fi
}

run_g3() {
    require_source "$HOOK" "G3: cumulative_severity=warning -> additionalContext, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g3-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'warning', findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g3-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qi "additionalContext\|warning" ); then
        pass "G3: cumulative_severity=warning -> additionalContext, exit 0"
    else
        fail "G3: cumulative_severity=warning -> additionalContext, exit 0 (rc=$rc, out=$out)"
    fi
}

run_g4() {
    require_source "$HOOK" "G4: cumulative_severity=notice -> additionalContext, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g4-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'notice', findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g4-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qi "additionalContext\|notice" ); then
        pass "G4: cumulative_severity=notice -> additionalContext, exit 0"
    else
        fail "G4: cumulative_severity=notice -> additionalContext, exit 0 (rc=$rc, out=$out)"
    fi
}

run_g5() {
    require_source "$HOOK" "G5: all null -> exit 0 {}" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g5-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g5-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G5: all null -> exit 0 {}"
    else
        fail "G5: all null -> exit 0 {} (rc=$rc, out=$out)"
    fi
}

run_g6() {
    require_source "$HOOK" "G6: stop_hook_active=true -> exit 0 immediately" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g6-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(echo '{"stop_hook_active":true,"session_id":"g6-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "G6: stop_hook_active=true -> exit 0 immediately"
    else
        fail "G6: stop_hook_active=true -> exit 0 immediately (rc=$rc, out=$out)"
    fi
}

run_g7() {
    require_source "$HOOK" "G7: state file missing -> exit 0 {} fail-open" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{"stop_hook_active":false,"session_id":"g7-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G7: state file missing -> exit 0 {} fail-open"
    else
        fail "G7: state file missing -> exit 0 {} fail-open (rc=$rc, out=$out)"
    fi
}

run_g8() {
    require_source "$HOOK" "G8: malformed JSON state file -> exit 0 {} fail-open" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # write garbage to expected state path
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
fs.writeFileSync(w.getStatePath('g8-sid'), 'not-valid-json{{{');
" >/dev/null 2>&1
    out=$(echo '{"stop_hook_active":false,"session_id":"g8-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G8: malformed JSON state file -> exit 0 {} fail-open"
    else
        fail "G8: malformed JSON state file -> exit 0 {} fail-open (rc=$rc, out=$out)"
    fi
}

run_g9() {
    require_source "$HOOK" "G9: WORKFLOW_OFF marker -> exit 0 {}" || return
    local tmp wfdir out rc
    tmp="$(mktemp -d)"; wfdir="$(mktemp -d)"
    touch "$wfdir/g9-sid.workflow-off"
    seed_state "$tmp" "g9-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g9-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" CLAUDE_WORKFLOW_DIR="$wfdir" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$wfdir"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "G9: WORKFLOW_OFF marker -> exit 0 {}"
    else
        fail "G9: WORKFLOW_OFF marker -> exit 0 {} (rc=$rc, out=$out)"
    fi
}

run_g10() {
    require_source "$HOOK" "G10: next_check_at + cumulative_severity=warning -> both refs in context" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "g10-sid" "{ next_check_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: 'warning', findings: [] }"
    out=$(echo '{"stop_hook_active":false,"session_id":"g10-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qi "supervisor.md" ) && ( echo "$out" | grep -qi "warning" ); then
        pass "G10: next_check_at + cumulative_severity=warning -> both refs in context"
    else
        fail "G10: next_check_at + cumulative_severity=warning -> both refs in context (rc=$rc, out=$out)"
    fi
}

run_g1
run_g2
run_g3
run_g4
run_g5
run_g6
run_g7
run_g8
run_g9
run_g10

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
