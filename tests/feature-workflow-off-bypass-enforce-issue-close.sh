#!/bin/bash
# tests/feature-workflow-off-bypass-enforce-issue-close.sh
#
# PR2: hooks/enforce-issue-close.js must early-return (exit 0) when
# <workflowDir>/<sid>.workflow-off marker exists for the calling session.
#
# Contract (existing hook behavior):
#   - bare `gh issue close N` from Bash → blocked (exit 2 with reason to stderr).
#   - ISSUE_CLOSE_SKILL=1 inherited env → bypass (exit 0).
# New contract (this PR):
#   - workflow-off marker present + valid sid → bypass (exit 0).
#   - traversal sid → bypass does NOT apply.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/enforce-issue-close.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eissueclose-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (hooks/enforce-issue-close.js not present)"
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

# A Bash tool payload that, without bypass, would be blocked by enforce-issue-close.
build_close_payload() {
    local sid="$1" n="$2"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    # Avoid embedding the literal token sequence that may trip outer wrappers.
    q_cmd="$(json_quote "gh issue close $n")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$q_sid" "$q_cmd"
}

HOOK_OUT=""
HOOK_ERR=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    local errfile="$TMPDIR_BASE/.err.$$"
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u ISSUE_CLOSE_SKILL \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>"$errfile")" || HOOK_RC=$?
    HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
}

# ============================================================================
# Tests
# ============================================================================

# A: No marker → bare close attempt blocked (exit 2 + stderr).
test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 2 ]; then
        fail "A: expected exit 2 but got rc=$HOOK_RC (stderr=$HOOK_ERR)"
        return
    fi
    if echo "$HOOK_ERR" | grep -q "issue-close-finalize"; then
        pass "A: no marker → close blocked (exit 2, points at /issue-close-finalize)"
    else
        fail "A: stderr missing /issue-close-finalize hint (stderr=$HOOK_ERR)"
    fi
}

# B: Marker present + valid sid → bypass (exit 0).
test_B_marker_bypasses() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_close_payload "$sid" 42)"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 0 ]; then
        pass "B: marker present → close bypass granted (exit 0)"
    else
        fail "B: marker present → expected exit 0 but got rc=$HOOK_RC (stderr=$HOOK_ERR; bypass not implemented?)"
    fi
}

# C: Traversal sid → bypass NOT granted, hook still blocks.
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_close_payload "../evil" 42)"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$HOOK_RC" -eq 2 ]; then
        pass "C: traversal sid → bypass NOT granted, hook still blocks (exit 2)"
    else
        fail "C: traversal sid wrongly bypassed (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

run_all() {
    test_A_no_marker_blocks
    test_B_marker_bypasses
    test_C_traversal_sid_no_bypass
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_ISSUE_CLOSE_INNER:-}" ]; then
        _BYPASS_ISSUE_CLOSE_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
