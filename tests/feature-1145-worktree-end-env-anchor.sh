#!/usr/bin/env bash
# tests/feature-1145-worktree-end-env-anchor.sh
# Tests: hooks/lib/worktree-end-env-anchor.js
# Tags: supervisor, em-supervisor, worktree-end, env-anchor, we15, scope:issue-specific, pwsh-not-required
# L1 unit tests for isWorktreeEndEnv(sessionId) — detects worktree-end cleanup phase
# via <sid>-wt-cleanup-active marker file presence (NOT env-json content).
# Fail-open (false) on marker absent / invalid sessionId.

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
    fail "T-anchor: hooks/lib/worktree-end-env-anchor.js not present"
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

# --- T-anchor-1: marker file present → true ---
run_t1() {
    local tmp tmp_node sid out rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor1-sid-$$"
    touch "$tmp/${sid}-wt-cleanup-active"
    out=$(call_anchor "$tmp_node" "$sid"); rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-anchor-1: node must exit 0, got rc=$rc"; return; fi
    if [ "$out" != "true" ]; then fail "T-anchor-1: marker file present must return true, got '$out'"; return; fi
    pass "T-anchor-1: marker file <sid>-wt-cleanup-active present → true"
}

# --- T-anchor-2: marker file absent → false ---
run_t2() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor2-sid-$$"
    # no file written
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-2: no marker file must return false, got '$out'"; return; fi
    pass "T-anchor-2: marker file absent → false"
}

# --- T-anchor-3: only env json written, no marker → false (ENOENT for marker) ---
run_t3() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor3-sid-$$"
    # Write old-style env json but NOT the new marker file
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-3: env-json only (no marker) must return false, got '$out'"; return; fi
    pass "T-anchor-3: env-json present but no marker → false (marker is the authoritative signal)"
}

# --- T-anchor-4: invalid SID (empty string) → false ---
run_t4() {
    local tmp tmp_node out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    out=$(call_anchor "$tmp_node" "")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-4: empty sessionId must return false, got '$out'"; return; fi
    pass "T-anchor-4: invalid SID (empty string) → false"
}

# --- T-anchor-5: invalid SID chars ("foo/bar") → false ---
run_t5() {
    local tmp tmp_node out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    out=$(call_anchor "$tmp_node" "foo/bar")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then fail "T-anchor-5: invalid-char sessionId must return false, got '$out'"; return; fi
    pass "T-anchor-5: invalid SID chars (\"foo/bar\") → false"
}

# --- T-anchor-6 (KEY REGRESSION): final-report-env.json present with valid content BUT marker absent → false ---
# This is the core regression guard: old code returned true based on env-json content alone,
# causing false-positive adaptive messages after WE-22 deleted the marker.
run_t6() {
    local tmp tmp_node sid out
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="anchor6-sid-$$"
    # Write valid env-json (old detection method) but NO marker file
    printf '%s' '{"WORKTREE_PATH":"/some/path","MERGE_SHA":"abc123"}' > "$tmp/${sid}-final-report-env.json"
    out=$(call_anchor "$tmp_node" "$sid")
    rm -rf "$tmp"
    if [ "$out" != "false" ]; then
        fail "T-anchor-6: env-json present (valid content) but no marker must return false — false-positive regression detected, got '$out'"
        return
    fi
    pass "T-anchor-6 (KEY REGRESSION): valid env-json + no marker → false (old code false-positives here)"
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
