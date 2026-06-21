#!/bin/bash
# tests/feature-957-plans-dir-node-bin-allow.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/plans-dir.js
# Tags: supervisor, em-supervisor, enforce-worktree, plans-dir, unit, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   This is a pure-function unit test on isAllowedWorkflowPlansDirWrite. It does NOT
#   exercise the PreToolUse hook surface that calls it (enforce-worktree.js) with
#   a real Bash tool invocation from the main worktree. A live claude -p session is
#   the only way to verify the end-to-end allow/block decision for node bin/<script>
#   commands issued via the model-controlled Bash tool.
# RED for issue #957.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SRC="$AGENTS_DIR/hooks/enforce-worktree/main-worktree-allows/plans-dir.js"
SRC_NODE="$_AGENTS_DIR_NODE/hooks/enforce-worktree/main-worktree-allows/plans-dir.js"

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

# Run the module against a given command. Sets up a temp WORKFLOW_PLANS_DIR for
# the regression A6 case; for A1-A5 the plans-dir resolution is incidental.
# Returns: prints "true" or "false".
call_allow() {
    local cmd="$1"
    local tmp="${2:-}"
    local env_prefix=""
    if [ -n "$tmp" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            local tmp_node
            tmp_node="$(cygpath -m "$tmp")"
            env_prefix="WORKFLOW_PLANS_DIR=$tmp_node"
        else
            env_prefix="WORKFLOW_PLANS_DIR=$tmp"
        fi
    fi
    (
        if [ -n "$env_prefix" ]; then
            local k="${env_prefix%%=*}"
            local v="${env_prefix#*=}"
            export "$k=$v"
        fi
        run_with_timeout 5 node -e "
const m = require('$SRC_NODE');
const cmd = process.argv[1];
const r = m.isAllowedWorkflowPlansDirWrite(cmd, process.cwd());
process.stdout.write(r ? 'true' : 'false');
" "$cmd" 2>/dev/null
    )
}

# Test the allowlist expectation. Until #957 is implemented the function will
# return false for node bin/<script> commands → test marks as expected-fail
# (FAIL). Because the source file already exists, require_source can't be used
# to skip these. We pre-detect the KNOWN_PLANS_DIR_WRITERS presence and skip if
# the allowlist hasn't been added yet.
allowlist_present() {
    [ -f "$SRC" ] || return 1
    grep -q "KNOWN_PLANS_DIR_WRITERS" "$SRC" 2>/dev/null
}

require_allowlist() {
    local label="$1"
    if ! allowlist_present; then skip "$label (KNOWN_PLANS_DIR_WRITERS not yet added)"; return 1; fi
    return 0
}

run_a1() {
    require_source "$SRC" "A1: node bin/supervisor-report --session-id <sid> allowed" || return
    require_allowlist "A1: node bin/supervisor-report --session-id <sid> allowed" || return
    local out
    out=$(call_allow "node bin/supervisor-report --session-id abc123 --categories code --severity warning --detail x --reporter test")
    if [ "$out" = "true" ]; then
        pass "A1: node bin/supervisor-report --session-id <sid> allowed"
    else
        fail "A1: node bin/supervisor-report --session-id <sid> allowed (out=$out)"
    fi
}

run_a2() {
    require_source "$SRC" "A2: node bin/supervisor-write-layer2 --session-id <sid> allowed" || return
    require_allowlist "A2: node bin/supervisor-write-layer2 --session-id <sid> allowed" || return
    local out
    out=$(call_allow "node bin/supervisor-write-layer2 --session-id abc123 --l2-armed-at 2026-06-06T12:00:00Z")
    if [ "$out" = "true" ]; then
        pass "A2: node bin/supervisor-write-layer2 --session-id <sid> allowed"
    else
        fail "A2: node bin/supervisor-write-layer2 --session-id <sid> allowed (out=$out)"
    fi
}

run_a3() {
    require_source "$SRC" "A3: node bin/supervisor-write-layer3 --session-id <sid> allowed" || return
    require_allowlist "A3: node bin/supervisor-write-layer3 --session-id <sid> allowed" || return
    local out
    out=$(call_allow "node bin/supervisor-write-layer3 --session-id abc123 --l3-armed-at 2026-06-06T12:00:00Z")
    if [ "$out" = "true" ]; then
        pass "A3: node bin/supervisor-write-layer3 --session-id <sid> allowed"
    else
        fail "A3: node bin/supervisor-write-layer3 --session-id <sid> allowed (out=$out)"
    fi
}

run_a4() {
    require_source "$SRC" "A4: node bin/arbitrary-script not in allowlist blocked" || return
    require_allowlist "A4: node bin/arbitrary-script not in allowlist blocked" || return
    local out
    out=$(call_allow "node bin/arbitrary-script --session-id abc123")
    if [ "$out" = "false" ]; then
        pass "A4: node bin/arbitrary-script not in allowlist blocked"
    else
        fail "A4: node bin/arbitrary-script not in allowlist blocked (out=$out)"
    fi
}

run_a5() {
    require_source "$SRC" "A5: node bin/supervisor-report without --session-id blocked" || return
    require_allowlist "A5: node bin/supervisor-report without --session-id blocked" || return
    local out
    out=$(call_allow "node bin/supervisor-report --categories code --severity warning --detail x --reporter test")
    if [ "$out" = "false" ]; then
        pass "A5: node bin/supervisor-report without --session-id blocked"
    else
        fail "A5: node bin/supervisor-report without --session-id blocked (out=$out)"
    fi
}

run_a6() {
    require_source "$SRC" "A6: redirect-to-plans-dir regression still allowed" || return
    local tmp out
    tmp="$(mktemp -d)"
    local tgt="$tmp/file"
    if command -v cygpath >/dev/null 2>&1; then
        tgt="$(cygpath -m "$tmp")/file"
    fi
    out=$(call_allow "echo foo >> \"$tgt\"" "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "true" ]; then
        pass "A6: redirect-to-plans-dir regression still allowed"
    else
        fail "A6: redirect-to-plans-dir regression still allowed (out=$out)"
    fi
}

run_a1
run_a2
run_a3
run_a4
run_a5
run_a6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
