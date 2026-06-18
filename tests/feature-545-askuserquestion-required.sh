#!/bin/bash
# tests/feature-545-askuserquestion-required.sh
# Tests: hooks/stop-askuserquestion-required.js, settings.json
# Tags: stop, hook, askuserquestion, user_verified, scope:545
# Tests for issue #545 — Stop hook that enforces a preceding AskUserQuestion
# tool_use before WORKFLOW_USER_VERIFIED sentinel emission.
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if stop-askuserquestion-required.js
#   is not wired into settings.json, the pre-flight gate is fully absent at runtime
#   even though these tests pass because they invoke the hook script directly
# - real Claude Code transcript format differences — tests use minimal crafted JSONL
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
#   fires at WORKFLOW_USER_VERIFIED preflight when settings.json changes are staged

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/stop-askuserquestion-required.js"

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

make_fixture() {
    local path="$1"; shift
    for line in "$@"; do printf '%s\n' "$line"; done > "$path"
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# W545-1 — USER_VERIFIED pre-flight without AskUserQuestion -> decision:block, exit 2
run_w545_1() {
    require_source "$HOOK" "W545-1: USER_VERIFIED without AskUserQuestion -> decision:block, exit 2" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"verify"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_USER_VERIFIED: implementation works>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    out=$(printf '{"stop_hook_active":false,"session_id":"w545-1-sid","transcript_path":"%s"}' "$tp" \
        | run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "W545-1: USER_VERIFIED without AskUserQuestion -> decision:block, exit 2"
    else
        fail "W545-1: USER_VERIFIED without AskUserQuestion -> decision:block, exit 2 (rc=$rc, out=$out)"
    fi
}

# W545-2 — USER_VERIFIED pre-flight with AskUserQuestion present -> exit 0
run_w545_2() {
    require_source "$HOOK" "W545-2: USER_VERIFIED with AskUserQuestion present -> exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"verify"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"AskUserQuestion","input":{"question":"OK?"}}]}}' \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"yes"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"echo \"<<WORKFLOW_USER_VERIFIED: implementation works>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    out=$(printf '{"stop_hook_active":false,"session_id":"w545-2-sid","transcript_path":"%s"}' "$tp" \
        | run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "\"decision\":\"block\"" ); then
        pass "W545-2: USER_VERIFIED with AskUserQuestion present -> exit 0"
    else
        fail "W545-2: USER_VERIFIED with AskUserQuestion present -> exit 0 (rc=$rc, out=$out)"
    fi
}

run_w545_1
run_w545_2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
