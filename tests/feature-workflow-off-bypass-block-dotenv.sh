#!/bin/bash
# tests/feature-workflow-off-bypass-block-dotenv.sh
# Tests: hooks/block-dotenv.js
# Tags: dotenv, secrets, hook, workflow, bin
#
# PR2: hooks/block-dotenv.js must early-return (approve) when
# <workflowDir>/<sid>.workflow-off marker exists for the calling session.
#
# Contract:
#   - With NO marker, Read on .env still blocks (baseline regression).
#   - With marker present + valid sid, Read on .env approves (bypass active).
#   - With invalid sid (traversal), bypass MUST NOT apply (still blocks).
#   - Idempotent: two consecutive calls with marker both approve.
#
# TDD note: tests "marker present → approve" will fail until block-dotenv.js
# adds the isWorkflowOff(sid) early-return.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/block-dotenv.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eblockdotenv-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (hooks/block-dotenv.js not present)"
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

write_marker_file() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build a PreToolUse Read payload for a .env file.
build_read_dotenv_payload() {
    local sid="$1" fp="$2"
    local q_sid q_fp
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$fp")"
    printf '{"session_id":%s,"tool_name":"Read","tool_input":{"file_path":%s}}' \
        "$q_sid" "$q_fp"
}

build_read_dotenv_payload_no_sid() {
    local fp="$1"
    local q_fp; q_fp="$(json_quote "$fp")"
    printf '{"tool_name":"Read","tool_input":{"file_path":%s}}' "$q_fp"
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
# A: baseline + marker bypass
# ============================================================================

test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_read_dotenv_payload "$sid" "/repo/.env")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker → Read on .env blocked (baseline)"
    else
        fail "A: expected block but got: $HOOK_OUT"
    fi
}

test_B_marker_approves() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_read_dotenv_payload "$sid" "/repo/.env")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "B: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "B: marker present → expected approve but got block (bypass not implemented?): $HOOK_OUT"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "B: marker present → Read on .env approved (workflow-off bypass)"
    else
        fail "B: expected approve but got: $HOOK_OUT"
    fi
}

test_C_traversal_sid_does_not_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Plant a marker outside wfdir at the resolved path of `../evil`
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_read_dotenv_payload "../evil" "/repo/.env")"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "C: traversal sid ../evil → bypass NOT granted, still blocked"
    else
        fail "C: traversal sid wrongly bypassed: $HOOK_OUT"
    fi
}

test_D_idempotent_double_call() {
    require_hook "D" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_read_dotenv_payload "$sid" "/repo/.env")"
    run_hook "$payload" "$wfdir"
    local out1="$HOOK_OUT" rc1="$HOOK_RC"
    run_hook "$payload" "$wfdir"
    local out2="$HOOK_OUT" rc2="$HOOK_RC"
    if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
        fail "D: hook crashed (rc1=$rc1 rc2=$rc2; out1=$out1 out2=$out2)"
        return
    fi
    if echo "$out1" | grep -q '"decision":"approve"' \
       && echo "$out2" | grep -q '"decision":"approve"'; then
        pass "D: idempotent — two consecutive calls with marker both approve"
    else
        fail "D: expected both approve (out1=$out1 out2=$out2)"
    fi
}

# Extra: no session_id at all → cannot bypass, baseline block applies.
test_E_no_session_id_blocks() {
    require_hook "E" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_read_dotenv_payload_no_sid "/repo/.env")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "E: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "E: no session_id → Read on .env still blocked (fail-closed)"
    else
        fail "E: expected block but got: $HOOK_OUT"
    fi
}

run_all() {
    test_A_no_marker_blocks
    test_B_marker_approves
    test_C_traversal_sid_does_not_bypass
    test_D_idempotent_double_call
    test_E_no_session_id_blocks
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_BLOCK_DOTENV_INNER:-}" ]; then
        _BYPASS_BLOCK_DOTENV_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
