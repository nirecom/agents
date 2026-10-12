#!/bin/bash
# tests/hooks/feature-workflow-off-bypass-workflow-gate.sh
# Tests: hooks/workflow-gate.js
# Tags: workflow, gate, hook, bin, git, scope:issue-specific

# PR2: hooks/workflow-gate.js approves early when <workflowDir>/<sid>.workflow-off exists.
# Contract:
#   - Without marker, `git commit` with a begun, incomplete state → block (baseline).
#   - Without marker and without state (WF not begun) → approve (#1633).
#   - With marker + valid sid → approve.
#   - With traversal sid → bypass MUST NOT apply (still block).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi
HOOK_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/workflow-gate.js"

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

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR
# isolation (#2512): the state dir is pinned file-wide too, not only per hook call.
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_STATE_DIR"

# The hook is launched from a copy of this checkout, which setup_repo attaches to the repo it
# builds (kept from the #1138 checkout-scoped rule; since #1633 the scope is the state's cwd).
# shellcheck source=tests/lib/session-repo-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"
GATE_CHECKOUT="$TMPDIR_BASE/gate-checkout"
session_repo_fixture_create "$GATE_CHECKOUT" || { echo "FAIL: cannot copy the checkout for the gate"; exit 1; }
HOOK_JS="$(session_repo_fixture_path "$GATE_CHECKOUT" hooks/workflow-gate.js)"

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
    session_repo_fixture_attach "$GATE_CHECKOUT" "$repo" || return 1
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
        env \
        "WORKFLOW_STATE_DIR=$wfdir" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# write_begun_state <wfdir> <sid> — workflow_init complete (the WF has begun), every other
# step pending, no cwd (target set unknown → checked, #1633).
write_begun_state() {
    local wfdir="$1" sid="$2"
    node -e "
const fs = require('fs'), path = require('path');
const { VALID_STEPS } = require(process.argv[1] + '/hooks/workflow-state.js');
const now = new Date().toISOString();
const steps = {};
for (const s of VALID_STEPS) steps[s] = { status: 'pending', updated_at: null };
steps.workflow_init = { status: 'complete', updated_at: now };
const st = { version: 1, session_id: process.argv[2], created_at: now, steps };
fs.writeFileSync(path.join(process.argv[3], process.argv[2] + '.json'), JSON.stringify(st, null, 2));
" "$_SCRIPT_CHECKOUT_ROOT_NODE" "$sid" "$wfdir"
}

# A: No marker, begun + incomplete workflow state → git commit blocked (baseline).
test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_repo "a-repo")"
    write_begun_state "$wfdir" "$sid"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker + begun incomplete state → git commit blocked (baseline)"
    else
        fail "A: expected block but got: $HOOK_OUT"
    fi
}

# A2: No marker, no workflow state → the WF has not begun → approve (#1633).
test_A2_no_state_approves() {
    require_hook "A2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession124"
    local repo; repo="$(setup_repo "a2-repo")"
    local payload; payload="$(build_commit_payload "$sid" "$repo")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A2: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "A2: no marker + no state (WF not begun) → git commit approved"
    else
        fail "A2: expected approve but got: $HOOK_OUT"
    fi
}

# B: Marker present + begun state → approve (workflow-off bypass).
# The fixture mirrors A: same begun+incomplete state, only the marker differs.
# This proves that the marker itself is what flips block→approve, not absent state.
test_B_marker_approves() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_repo "b-repo")"
    write_begun_state "$wfdir" "$sid"
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
        pass "B: marker present + begun incomplete state → git commit approved (workflow-off bypass)"
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
    test_A2_no_state_approves
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
