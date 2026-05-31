#!/bin/bash
# tests/feature-workflow-off-bypass-enforce-system-ops.sh
# Tests: hooks/enforce-system-ops.js
# Tags: workflow-off-bypass-enforce-system-ops
#
# PR2 invariant: hooks/enforce-system-ops.js must NEVER be bypassed by the
# workflow-off marker. System-state-changing operations require explicit user
# approval per rules/user-escalation.md (Rule 0) and rules/ops.md categories
# A-F. The workflow-off escape hatch must NOT widen this surface.
#
# Contract:
#   - winget install: blocks regardless of marker presence.
#   - npm install -g: blocks regardless of marker presence.
#   - Non-system commands (e.g. `npm install` per-repo) pass regardless.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/enforce-system-ops.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'esysops-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (hooks/enforce-system-ops.js not present)"
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

build_bash_payload() {
    local sid="$1" cmd="$2"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
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
        env -u CLAUDE_ENV_FILE -u SYSTEM_OPS_APPROVED \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>"$errfile")" || HOOK_RC=$?
    HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
}

# ============================================================================
# Tests
# ============================================================================

# A: No marker → winget install blocked (baseline; existing test surface).
test_A_no_marker_winget_blocked() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_bash_payload "$sid" "winget install foo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 2 ]; then
        pass "A: no marker → winget install blocked (exit 2)"
    else
        fail "A: expected exit 2 but got rc=$HOOK_RC (stderr=$HOOK_ERR)"
    fi
}

# B: KEY INVARIANT — marker present, winget install STILL blocked.
test_B_marker_does_not_bypass_winget() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_bash_payload "$sid" "winget install foo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 2 ]; then
        pass "B: marker present → winget install STILL blocked (no bypass — invariant)"
    else
        fail "B: marker wrongly bypassed system-ops (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

# C: Marker present, npm install -g STILL blocked.
test_C_marker_does_not_bypass_npm_global() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_bash_payload "$sid" "npm install -g typescript")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 2 ]; then
        pass "C: marker present → npm install -g STILL blocked (no bypass)"
    else
        fail "C: marker wrongly bypassed npm -g (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

# D: Non-system command (per-repo npm install) passes regardless of marker.
test_D_marker_passes_per_repo_npm() {
    require_hook "D" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_bash_payload "$sid" "npm install typescript")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -eq 0 ]; then
        pass "D: per-repo npm install passes (no system-ops trigger)"
    else
        fail "D: per-repo npm install unexpectedly blocked (rc=$HOOK_RC stderr=$HOOK_ERR)"
    fi
}

run_all() {
    test_A_no_marker_winget_blocked
    test_B_marker_does_not_bypass_winget
    test_C_marker_does_not_bypass_npm_global
    test_D_marker_passes_per_repo_npm
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_SYSOPS_INNER:-}" ]; then
        _BYPASS_SYSOPS_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
