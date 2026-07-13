#!/usr/bin/env bash
# tests/feature-1145-worktree-end-env-anchor.sh
# Tests: hooks/lib/worktree-end-env-anchor.js
# Tags: supervisor, em-supervisor, worktree-end, env-anchor, we15, scope:issue-specific, pwsh-not-required
# L1 unit tests for isWorktreeEndEnv(sessionId) — a pure helper (does NOT exist yet).
# Verifies detection of the worktree-end final-report-env schema vs session-close schema,
# and fail-open (false) on ENOENT / corrupt JSON / invalid sessionId.
# RED-EXPECTED: source hooks/lib/worktree-end-env-anchor.js not yet implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

ANCHOR="$AGENTS_DIR/hooks/lib/worktree-end-env-anchor.js"
ANCHOR_NODE="$_AGENTS_DIR_NODE/hooks/lib/worktree-end-env-anchor.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'anchor1'; }

if [ ! -f "$ANCHOR" ]; then
    fail "T-anchor: hooks/lib/worktree-end-env-anchor.js not present (RED-EXPECTED — not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

tmp_node_for() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# Invoke isWorktreeEndEnv with a given plans-dir + sessionId; echoes "true"/"false".
call_anchor() {
    local plansdir="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$plansdir" run_with_timeout 10 node -e "
const { isWorktreeEndEnv } = require('$ANCHOR_NODE');
console.log(isWorktreeEndEnv('$sid') ? 'true' : 'false');
" 2>/dev/null
}

# --- T-anchor-1: valid worktree-end env → true ---
run_t1() {
    local tmp tmp_node sid out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor1-sid-$$"
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid"); rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-anchor-1: node must exit 0, got rc=$rc"; return; fi
    if [ "$out" != "true" ]; then fail "T-anchor-1: valid worktree-end env must return true, got '$out'"; return; fi
    pass "T-anchor-1: valid worktree-end env (WORKTREE_PATH + MERGE_SHA) → true"
}

# --- T-anchor-2: WORKTREE_PATH="" (session-close schema) → false ---
run_t2() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor2-sid-$$"
    printf '%s' '{"WORKTREE_PATH":"","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-2: empty WORKTREE_PATH must return false, got '$out'"; return; fi
    pass "T-anchor-2: WORKTREE_PATH=\"\" (session-close schema) → false"
}

# --- T-anchor-3: MERGE_SHA field absent → false ---
run_t3() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor3-sid-$$"
    printf '%s' '{"WORKTREE_PATH":"/some/path","OTHER_FIELD":"x"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-3: absent MERGE_SHA must return false, got '$out'"; return; fi
    pass "T-anchor-3: MERGE_SHA field absent → false"
}

# --- T-anchor-4: file ENOENT → false (fail-open) ---
run_t4() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor4-sid-$$"
    # no file written
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-4: ENOENT must return false, got '$out'"; return; fi
    pass "T-anchor-4: file ENOENT → false (fail-open)"
}

# --- T-anchor-5: corrupt JSON → false ---
run_t5() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor5-sid-$$"
    printf '%s' 'not json at all' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-5: corrupt JSON must return false, got '$out'"; return; fi
    pass "T-anchor-5: corrupt JSON → false"
}

# --- T-anchor-6: empty file → false ---
run_t6() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor6-sid-$$"
    : > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-6: empty file must return false, got '$out'"; return; fi
    pass "T-anchor-6: empty file → false"
}

# --- T-anchor-7: sessionId is "" → false ---
run_t7() {
    local tmp tmp_node out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    out=$(call_anchor "$tmp_node" "")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-7: empty sessionId must return false, got '$out'"; return; fi
    pass "T-anchor-7: sessionId is \"\" → false"
}

# --- T-anchor-8: sessionId has invalid chars "foo/bar" → false ---
run_t8() {
    local tmp tmp_node out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    out=$(call_anchor "$tmp_node" "foo/bar")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-8: invalid-char sessionId must return false, got '$out'"; return; fi
    pass "T-anchor-8: sessionId has invalid chars \"foo/bar\" → false"
}

# --- T-anchor-9: WORKTREE_PATH is null (not a string) → false ---
run_t9() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor9-sid-$$"
    printf '%s' '{"WORKTREE_PATH":null,"MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-9: null WORKTREE_PATH must return false, got '$out'"; return; fi
    pass "T-anchor-9: WORKTREE_PATH is null (not a string) → false"
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
