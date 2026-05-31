#!/bin/bash
# tests/feature-workflow-off-bypass-enforce-worktree.sh
# Tests: hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, workflow, bin
#
# PR2: hooks/enforce-worktree.js must early-return (approve) when
# <workflowDir>/<sid>.workflow-off marker exists for the calling session.
#
# Distinct from the existing worktree-off bypass (`<sid>.worktree-off`):
# this is the WORKFLOW-level switch and shares the same isWorkflowOff(sid)
# helper used by the other four PR2 hooks. When the bypass fires, the hook
# emits the workflow-off notice to stderr.
#
# Contract:
#   - Without marker, Edit from main checkout → block (baseline).
#   - With marker + valid sid → approve AND stderr contains
#     "ENFORCE_WORKFLOW is OFF" (from workflowOffNoticeText).
#   - Traversal sid → bypass does NOT apply.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eworkflow-wt-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (hooks/enforce-worktree.js not present)"
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

setup_main_checkout() {
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
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_guard_payload_write() {
    local sid="$1" tname="$2" fp="$3"
    local q_sid q_fp
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$fp")"
    printf '{"session_id":%s,"tool_name":"%s","tool_input":{"file_path":%s,"content":"hi"}}' \
        "$q_sid" "$tname" "$q_fp"
}

GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1" wfdir="$2" repo_scope="$3"
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo_scope" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK_JS" 2>&1)" || GUARD_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# A: No marker, Edit from main checkout → blocked (baseline).
test_A_no_marker_blocks() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_main_checkout "a-main")"
    local payload; payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    run_guard "$payload" "$wfdir" "$repo"
    if [ "$GUARD_RC" -ne 0 ]; then
        fail "A: guard crashed rc=$GUARD_RC (out: $GUARD_OUT)"
        return
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker, Write from main checkout → blocked (baseline)"
    else
        fail "A: expected block but got: $GUARD_OUT"
    fi
}

# B: Marker present + valid sid → approve, and stderr contains workflow-off notice.
test_B_marker_approves_and_emits_notice() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local repo; repo="$(setup_main_checkout "b-main")"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    run_guard "$payload" "$wfdir" "$repo"
    if [ "$GUARD_RC" -ne 0 ]; then
        fail "B: guard crashed rc=$GUARD_RC (out: $GUARD_OUT)"
        return
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        fail "B: marker present → expected approve but got block (bypass not implemented?): $GUARD_OUT"
        return
    fi
    if ! echo "$GUARD_OUT" | grep -q "ENFORCE_WORKFLOW is OFF"; then
        fail "B: marker present → expected workflow-off notice in stderr (got: $GUARD_OUT)"
        return
    fi
    pass "B: marker present → Write from main checkout approved + notice emitted"
}

# C: Traversal sid → bypass NOT granted, write still blocked.
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "c-main")"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_guard_payload_write "../evil" "Write" "$repo/foo.txt")"
    run_guard "$payload" "$wfdir" "$repo"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$GUARD_RC" -ne 0 ]; then
        fail "C: guard crashed rc=$GUARD_RC (out: $GUARD_OUT)"
        return
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        pass "C: traversal sid → bypass NOT granted, write still blocked"
    else
        fail "C: traversal sid wrongly bypassed: $GUARD_OUT"
    fi
}

run_all() {
    test_A_no_marker_blocks
    test_B_marker_approves_and_emits_notice
    test_C_traversal_sid_no_bypass
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_ENFORCE_WT_INNER:-}" ]; then
        _BYPASS_ENFORCE_WT_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
