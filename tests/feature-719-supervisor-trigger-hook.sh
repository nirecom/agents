#!/bin/bash
# tests/feature-719-supervisor-trigger-hook.sh
# Tests: hooks/supervisor-trigger.js (PostToolUse — wakeup writer)
# Tags: supervisor, em-supervisor, hook, layer2
# RED for issue #719.
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json PostToolUse hooks — if supervisor-trigger.js is not
#   wired, C2 escape-hatch detection never fires but these tests still pass because they
#   invoke the hook script directly
# - integration with the real Claude Code Bash tool runner — tests inject crafted stdin;
#   live hook receives actual tool_input fields from Claude Code
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
#   fires at WORKFLOW_USER_VERIFIED preflight when settings.json changes are staged

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-trigger.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-trigger.js"
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

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
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
st.alert = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Like seed_state but also injects a warning-severity layer1 finding.
# Required for escape-hatch arm tests after fix #975 (hasBlockingFinding gate).
seed_state_with_l1_finding() {
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert = $layer2_json;
st.layer1.findings = [{ categories: ['workflow'], severity: 'warning', detail: 'blocking-finding', reporter: 'test', timestamp: new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_field() {
    local tmp="$1" sid="$2" path="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const parts = '$path'.split('.');
let cur = st;
for (const p of parts) { if (cur == null) break; cur = cur[p]; }
process.stdout.write(JSON.stringify(cur));
" 2>/dev/null
}

run_t1() {
    require_source "$HOOK" "T1: no state file + non-C2 command -> no state file created" || return
    local tmp val rc
    tmp="$(mktemp -d)"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"t1-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t1-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$val" ] || [ "$val" = "null" ] ); then
        pass "T1: no state file + non-C2 command -> no state file created"
    else
        fail "T1: no state file + non-C2 command -> no state file created (rc=$rc, val=$val)"
    fi
}

run_t2() {
    require_source "$HOOK" "T2: non-C2 command with existing state -> alert_armed_at stays null (last_run_at not used as cooldown)" || return
    local tmp out rc val
    tmp="$(mktemp -d)"
    local ts
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state "$tmp" "t2-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t2-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    val=$(read_field "$tmp" "t2-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "T2: non-C2 command with existing state -> alert_armed_at stays null (last_run_at not used as cooldown)"
    else
        fail "T2: non-C2 command with existing state -> alert_armed_at stays null (last_run_at not used as cooldown) (rc=$rc, val=$val, out=$out)"
    fi
}

run_t3() {
    require_source "$HOOK" "T3: non-C2 command with old last_run_at -> alert_armed_at stays null (no wall-clock timer)" || return
    local tmp rc val
    tmp="$(mktemp -d)"
    local ts
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-600000).toISOString())")
    seed_state "$tmp" "t3-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"t3-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t3-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "T3: non-C2 command with old last_run_at -> alert_armed_at stays null (no wall-clock timer)"
    else
        fail "T3: non-C2 command with old last_run_at -> alert_armed_at stays null (no wall-clock timer) (rc=$rc, val=$val)"
    fi
}

run_t4() {
    require_source "$HOOK" "T4: alert_armed_at already set -> idempotent" || return
    local tmp rc val
    tmp="$(mktemp -d)"
    seed_state "$tmp" "t4-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t4-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t4-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"2026-06-06T12:00:00Z\"" ]; then
        pass "T4: alert_armed_at already set -> idempotent"
    else
        fail "T4: alert_armed_at already set -> idempotent (rc=$rc, val=$val)"
    fi
}

run_t5() {
    require_source "$HOOK" "T5: cumulative_severity=warning -> additionalContext" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "t5-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'warning', findings: [] }"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t5-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # accept "warning" OR "Layer 2" OR the warning marker in output
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qiE "(warning|layer 2|⚠)" ); then
        pass "T5: cumulative_severity=warning -> additionalContext"
    else
        fail "T5: cumulative_severity=warning -> additionalContext (rc=$rc, out=$out)"
    fi
}

run_t6() {
    require_source "$HOOK" "T6: cumulative_severity=error -> additionalContext, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "t6-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'error', findings: [] }"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t6-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qiE "(error|alert mode|blocking)" ); then
        pass "T6: cumulative_severity=error -> additionalContext, exit 0"
    else
        fail "T6: cumulative_severity=error -> additionalContext, exit 0 (rc=$rc, out=$out)"
    fi
}

run_t7() {
    require_source "$HOOK" "T7: WORKFLOW_OFF marker -> {} no-op" || return
    local tmp wfdir out rc
    tmp="$(mktemp -d)"; wfdir="$(mktemp -d)"
    touch "$wfdir/t7-sid.workflow-off"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t7-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" CLAUDE_WORKFLOW_DIR="$wfdir" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$wfdir"
    # accept empty or {} as no-op
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "T7: WORKFLOW_OFF marker -> {} no-op"
    else
        fail "T7: WORKFLOW_OFF marker -> {} no-op (rc=$rc, out=$out)"
    fi
}

run_t8() {
    require_source "$HOOK" "T8: malformed stdin -> exit 0 {}" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo 'not-json' | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "T8: malformed stdin -> exit 0 {}"
    else
        fail "T8: malformed stdin -> exit 0 {} (rc=$rc, out=$out)"
    fi
}

run_t9() {
    require_source "$HOOK" "T9: unresolvable session id -> exit 0 {}" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{}' | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( [ -z "$out" ] || [ "$out" = "{}" ] ); then
        pass "T9: unresolvable session id -> exit 0 {}"
    else
        fail "T9: unresolvable session id -> exit 0 {} (rc=$rc, out=$out)"
    fi
}

run_t10() {
    require_source "$HOOK" "T10: non-Bash tool input -> exit 0, parseable JSON" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{"tool_name":"Read","tool_input":{"file_path":"x"},"session_id":"t10-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # accept any exit 0; output may be empty, {}, or JSON with additionalContext
    if [ $rc -eq 0 ]; then
        # if output is non-empty, must be parseable JSON
        if [ -z "$out" ] || run_with_timeout 5 node -e "JSON.parse(process.argv[1])" "$out" >/dev/null 2>&1; then
            pass "T10: non-Bash tool input -> exit 0, parseable JSON"
        else
            fail "T10: non-Bash tool input -> exit 0, parseable JSON (rc=$rc, out=$out, not JSON)"
        fi
    else
        fail "T10: non-Bash tool input -> exit 0, parseable JSON (rc=$rc, out=$out)"
    fi
}

run_t11() {
    require_source "$HOOK" "T11: C2 escape-hatch command + blocking l1 finding -> sets alert_armed_at" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state_with_l1_finding "$tmp" "t11-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: testing>>\""},"session_id":"t11-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t11-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ]; then
        pass "T11: C2 escape-hatch command + blocking l1 finding -> sets alert_armed_at"
    else
        fail "T11: C2 escape-hatch command + blocking l1 finding -> sets alert_armed_at (rc=$rc, val=$val)"
    fi
}

run_t12() {
    require_source "$HOOK" "T12: C2 ON sentinel -> no alert_armed_at" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state "$tmp" "t12-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>\""},"session_id":"t12-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t12-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "T12: C2 ON sentinel -> no alert_armed_at"
    else
        fail "T12: C2 ON sentinel -> no alert_armed_at (rc=$rc, val=$val)"
    fi
}

run_t13() {
    require_source "$HOOK" "T13: ENFORCE_WORKTREE_OFF sentinel + blocking l1 finding -> sets alert_armed_at (C2 worktree path)" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state_with_l1_finding "$tmp" "t13-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: testing>>\""},"session_id":"t13-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t13-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ]; then
        pass "T13: ENFORCE_WORKTREE_OFF sentinel + blocking l1 finding -> sets alert_armed_at (C2 worktree path)"
    else
        fail "T13: ENFORCE_WORKTREE_OFF sentinel + blocking l1 finding -> sets alert_armed_at (C2 worktree path) (rc=$rc, val=$val)"
    fi
}

run_t14() {
    require_source "$HOOK" "T14: adversarial session_id (path traversal) -> fail-open, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"../evil"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "T14: adversarial session_id (path traversal) -> fail-open, exit 0"
    else
        fail "T14: adversarial session_id (path traversal) -> fail-open, exit 0 (rc=$rc, out=$out)"
    fi
}

run_t15() {
    require_source "$HOOK" "T15: ENFORCE_WORKFLOW_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state_with_l1_finding "$tmp" "t15-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>\""},"session_id":"t15-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t15-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ]; then
        pass "T15: ENFORCE_WORKFLOW_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at"
    else
        fail "T15: ENFORCE_WORKFLOW_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at (rc=$rc, val=$val)"
    fi
}

run_t16() {
    require_source "$HOOK" "T16: ENFORCE_WORKTREE_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state_with_l1_finding "$tmp" "t16-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF>>\""},"session_id":"t16-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t16-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ]; then
        pass "T16: ENFORCE_WORKTREE_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at"
    else
        fail "T16: ENFORCE_WORKTREE_OFF LOOKSLIKE variant + blocking l1 finding -> sets alert_armed_at (rc=$rc, val=$val)"
    fi
}

run_t17() {
    require_source "$HOOK" "T17: C2 escape-hatch when alert_armed_at already set -> idempotent (no-op)" || return
    local tmp val rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "t17-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: test>>\""},"session_id":"t17-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t17-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = '"2026-06-06T12:00:00Z"' ]; then
        pass "T17: C2 escape-hatch when alert_armed_at already set -> idempotent (no-op)"
    else
        fail "T17: C2 escape-hatch when alert_armed_at already set -> idempotent (no-op) (rc=$rc, val=$val)"
    fi
}

run_t18() {
    require_source "$HOOK" "T18: ENFORCE_WORKTREE_ON command -> no alert_armed_at (ON sentinels are not C2)" || return
    local tmp val rc ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state "$tmp" "t18-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: done>>\""},"session_id":"t18-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t18-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "T18: ENFORCE_WORKTREE_ON command -> no alert_armed_at (ON sentinels are not C2)"
    else
        fail "T18: ENFORCE_WORKTREE_ON command -> no alert_armed_at (ON sentinels are not C2) (rc=$rc, val=$val)"
    fi
}

run_t19() {
    require_source "$HOOK" "T19: cumulative_severity=notice -> additionalContext" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "t19-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: 'notice', findings: [] }"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"x"},"session_id":"t19-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qiE "(notice|layer 2)" ); then
        pass "T19: cumulative_severity=notice -> additionalContext"
    else
        fail "T19: cumulative_severity=notice -> additionalContext (rc=$rc, out=$out)"
    fi
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11
run_t12
run_t13
run_t14
run_t20() {
    require_source "$HOOK" "T20: C2 command + blocking l1 finding -> sets alert_armed_at" || return
    local tmp val rc
    tmp="$(mktemp -d)"
    seed_state_with_l1_finding "$tmp" "t20-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: testing>>\""},"session_id":"t20-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "t20-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ]; then
        pass "T20: C2 command + blocking l1 finding -> sets alert_armed_at"
    else
        fail "T20: C2 command + blocking l1 finding -> sets alert_armed_at (rc=$rc, val=$val)"
    fi
}

run_t21() {
    require_source "$HOOK" "T21: tool_input field entirely absent -> fail-open, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo '{"tool_name":"Bash","session_id":"t21-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "T21: tool_input field entirely absent -> fail-open, exit 0"
    else
        fail "T21: tool_input field entirely absent -> fail-open, exit 0 (rc=$rc, out=$out)"
    fi
}

run_t22() {
    require_source "$HOOK" "T22: C2 escape-hatch + cumSev=warning + blocking l1 finding -> sets alert_armed_at AND emits advisory" || return
    local tmp out rc val ts
    tmp="$(mktemp -d)"
    ts=$(run_with_timeout 5 node -e "console.log(new Date(Date.now()-60000).toISOString())")
    seed_state_with_l1_finding "$tmp" "t22-sid" "{ alert_armed_at: null, last_run_at: '$ts', cumulative_severity: 'warning', findings: [{\"categories\":[\"workflow\"],\"severity\":\"warning\",\"detail\":\"test-finding\",\"timestamp\":\"2026-06-06T12:00:00.000Z\"}] }"
    out=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: testing>>\""},"session_id":"t22-sid"}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    val=$(read_field "$tmp" "t22-sid" "alert.alert_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ] && ( echo "$out" | grep -qiE "(warning|layer 2)" ); then
        pass "T22: C2 escape-hatch + cumSev=warning + blocking l1 finding -> sets alert_armed_at AND emits advisory"
    else
        fail "T22: C2 escape-hatch + cumSev=warning + blocking l1 finding -> sets alert_armed_at AND emits advisory (rc=$rc, val=$val, out=$out)"
    fi
}

run_t15
run_t16
run_t17
run_t18
run_t19
run_t20
run_t21
run_t22

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
