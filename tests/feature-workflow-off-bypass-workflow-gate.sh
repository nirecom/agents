#!/bin/bash
# tests/feature-workflow-off-bypass-workflow-gate.sh
# Tests: hooks/workflow-gate.js
# Tags: workflow, gate, hook, bin, git
#
# PR2: hooks/workflow-gate.js must early-return (approve) when
# <workflowDir>/<sid>.workflow-off marker exists for the calling session.
#
# Contract:
#   - Without marker, `git commit` with no workflow state → block (baseline).
#   - With marker + valid sid → approve.
#   - With traversal sid → bypass MUST NOT apply (still block).

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
const d=path.join(os.tmpdir(),'ewfgate-'+process.pid).replace(/\\\\/g,'/');
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

write_marker_file() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

# Set up a real git repo with a staged file so workflow-gate has a repoDir to
# inspect (matches the workflow-and-chain test pattern).
setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "src" > "$repo/app.js"
    git -C "$repo" add app.js
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_commit_payload() {
    local sid="$1" repo="$2"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "git -C $repo commit -m \"test\"")"
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

# A: No marker, no workflow state → git commit blocked (baseline).
test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_repo "a-repo")"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker + no state → git commit blocked (baseline)"
    else
        fail "A: expected block but got: $HOOK_OUT"
    fi
}

# B: Marker present + valid sid → approve.
test_B_marker_approves() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_repo "b-repo")"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
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
        pass "B: marker present → git commit approved (workflow-off bypass)"
    else
        fail "B: expected explicit approve but got: $HOOK_OUT"
    fi
}

# C: Traversal sid must NOT grant bypass.
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_repo "c-repo")"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_commit_payload "../evil" "$repo")"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "C: traversal sid → bypass NOT granted, commit still blocked"
    else
        fail "C: traversal sid wrongly bypassed: $HOOK_OUT"
    fi
}

run_all() {
    test_A_no_marker_blocks
    test_B_marker_approves
    test_C_traversal_sid_no_bypass
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_WORKFLOW_GATE_INNER:-}" ]; then
        _BYPASS_WORKFLOW_GATE_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
