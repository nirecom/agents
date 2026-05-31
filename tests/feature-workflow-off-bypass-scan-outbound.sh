#!/bin/bash
# tests/feature-workflow-off-bypass-scan-outbound.sh
# Tests: hooks/scan-outbound.js
# Tags: scan, filter, outbound, hook, workflow
#
# PR2: hooks/scan-outbound.js must early-return (approve) when
# <workflowDir>/<sid>.workflow-off marker exists for the calling session.
#
# Contract:
#   - Without marker: hook runs normally (may approve or block depending on
#     content + public-repo detection — we don't assert behavior, only that
#     it doesn't crash).
#   - With marker + valid sid: hook approves immediately (no scan).
#   - With invalid (traversal) sid: bypass MUST NOT apply.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/scan-outbound.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'escanout-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (hooks/scan-outbound.js not present)"
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

# Build an Edit payload writing benign content. Note: scan-outbound detects
# private-info patterns; we use a clearly synthetic value so the test does not
# accidentally land in any blocklist.
build_edit_payload() {
    local sid="$1" fp="$2" new="$3"
    local q_sid q_fp q_new
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$fp")"
    q_new="$(json_quote "$new")"
    printf '{"session_id":%s,"tool_name":"Edit","tool_input":{"file_path":%s,"old_string":"x","new_string":%s}}' \
        "$q_sid" "$q_fp" "$q_new"
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

# Content that the scanner reliably flags: an RFC1918 private IPv4 literal.
# This avoids depending on any specific secret-like pattern.
PRIVATE_INFO_CONTENT='Internal note: gateway at 10.20.30.40 is offline.'

# A: Without marker, hook scans and blocks private-info content (baseline).
test_A_no_marker_blocks_private_info() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_edit_payload "$sid" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker → scan blocks private-info content (baseline)"
    else
        fail "A: expected block on private-info content but got: $HOOK_OUT"
    fi
}

# B: With marker present and valid sid, hook approves identical content (no scan).
test_B_marker_approves_immediately() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_edit_payload "$sid" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
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
        pass "B: marker present → hook approves immediately (workflow-off bypass)"
    else
        fail "B: expected explicit approve decision but got: $HOOK_OUT"
    fi
}

# C: Traversal sid must NOT bypass — same private-info content still blocks.
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_edit_payload "../evil" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "C: traversal sid → bypass NOT granted, private-info still blocks"
    else
        fail "C: traversal sid wrongly granted bypass: $HOOK_OUT"
    fi
}

run_all() {
    test_A_no_marker_blocks_private_info
    test_B_marker_approves_immediately
    test_C_traversal_sid_no_bypass
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_SCAN_OUTBOUND_INNER:-}" ]; then
        _BYPASS_SCAN_OUTBOUND_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
