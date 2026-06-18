#!/bin/bash
# tests/feature-372-enforce-worktree-on-warn.sh
# Tests: hooks/stop-enforce-worktree-on-warn.js, settings.json
# Tags: stop, hook, worktree, sentinel, scope:372
# Tests for issue #372 — Stop hook that warns when a WORKFLOW_ENFORCE_WORKTREE_OFF
# proposal in the transcript was never followed by a matching ON sentinel.
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if stop-enforce-worktree-on-warn.js
#   is not wired into settings.json, the warning gate is fully absent at runtime
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

HOOK="$AGENTS_DIR/hooks/stop-enforce-worktree-on-warn.js"

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

# W372-1 — transcript proposed WORKTREE_OFF with matching ON sentinel -> no warning
run_w372_1() {
    require_source "$HOOK" "W372-1: matched OFF+ON -> no warning, exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: temp>>\""}}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: done>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    out=$(printf '{"stop_hook_active":false,"session_id":"w372-1-sid","transcript_path":"%s"}' "$tp" \
        | run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # No warning means no additionalContext mentioning ENFORCE_WORKTREE_OFF
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi "ENFORCE_WORKTREE_OFF" ); then
        pass "W372-1: matched OFF+ON -> no warning, exit 0"
    else
        fail "W372-1: matched OFF+ON -> no warning, exit 0 (rc=$rc, out=$out)"
    fi
}

# W372-2 — transcript proposed WORKTREE_OFF with no matching ON -> warning present, exit 0
run_w372_2() {
    require_source "$HOOK" "W372-2: unmatched OFF -> additionalContext warning, exit 0" || return
    local tmp out rc tp
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: temp>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    out=$(printf '{"stop_hook_active":false,"session_id":"w372-2-sid","transcript_path":"%s"}' "$tp" \
        | run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ( echo "$out" | grep -qi "ENFORCE_WORKTREE_ON\|restore" ); then
        pass "W372-2: unmatched OFF -> additionalContext warning, exit 0"
    else
        fail "W372-2: unmatched OFF -> additionalContext warning, exit 0 (rc=$rc, out=$out)"
    fi
}

run_w372_1
run_w372_2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
