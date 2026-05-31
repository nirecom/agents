#!/bin/bash
# tests/feature-workflow-off-chain-guard.sh
# Tests: hooks/lib/sentinel-patterns.js., hooks/workflow-gate.js
# Tags: workflow, gate, hook, sentinel, bin
#
# Chain-guard tests for the new WORKFLOW_ENFORCE_WORKFLOW_OFF / _ON sentinels.
#
# workflow-gate.js Step 1 chain-guard already covers the entire
# WORKFLOW_[A-Za-z_]+ family via CHAIN_BOUNDARY_SENTINEL_DQ_RE in
# hooks/lib/sentinel-patterns.js. This means chains of the shape
#   echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>>" && <other>
# must be rejected (workflow-mark.js would otherwise silently drop the state
# update due to issue #110 all-or-nothing dispatch).
#
# Contract:
#   - Chained OFF sentinel + non-sentinel via `&&` → blocked.
#   - Standalone OFF sentinel (no chain) → approved (Bash echo of sentinel is
#     exempt; workflow-mark.js handles it on the PostToolUse side).
#   - Chained ON sentinel + non-sentinel → blocked (symmetric).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'echainguard-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        fail "$1 (hooks/workflow-gate.js not present)"
        return 1
    fi
    return 0
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local sid="$1" cmd="$2"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$q_sid" "$q_cmd"
}

HOOK_OUT=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# A: Chain form `<<...WORKFLOW_OFF: x>>" && rm -rf /tmp/foo` → blocked.
test_A_off_chain_blocked() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local cmd
    cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>>" && rm -rf /tmp/foo'
    local payload; payload="$(build_bash_payload "$sid" "$cmd")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: chained WORKFLOW_ENFORCE_WORKFLOW_OFF + non-sentinel → blocked"
    else
        fail "A: chain not blocked (got: $HOOK_OUT)"
    fi
}

# B: Standalone OFF sentinel → approved (PostToolUse handles state mutation).
test_B_off_standalone_allowed() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local cmd
    cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: standalone reason>>"'
    local payload; payload="$(build_bash_payload "$sid" "$cmd")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "B: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "B: standalone OFF sentinel wrongly blocked (out: $HOOK_OUT)"
        return
    fi
    pass "B: standalone WORKFLOW_ENFORCE_WORKFLOW_OFF sentinel allowed"
}

# C: Chained ON sentinel + non-sentinel → blocked (symmetric to A).
test_C_on_chain_blocked() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local cmd
    cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: y>>" && rm -rf /tmp/bar'
    local payload; payload="$(build_bash_payload "$sid" "$cmd")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "C: chained WORKFLOW_ENFORCE_WORKFLOW_ON + non-sentinel → blocked"
    else
        fail "C: ON chain not blocked (got: $HOOK_OUT)"
    fi
}

# D: Standalone ON sentinel → approved.
test_D_on_standalone_allowed() {
    require_hook "D" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local cmd
    cmd='echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: standalone reason>>"'
    local payload; payload="$(build_bash_payload "$sid" "$cmd")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "D: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "D: standalone ON sentinel wrongly blocked (out: $HOOK_OUT)"
        return
    fi
    pass "D: standalone WORKFLOW_ENFORCE_WORKFLOW_ON sentinel allowed"
}

run_all() {
    test_A_off_chain_blocked
    test_B_off_standalone_allowed
    test_C_on_chain_blocked
    test_D_on_standalone_allowed
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_CHAIN_GUARD_INNER:-}" ]; then
        _CHAIN_GUARD_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
