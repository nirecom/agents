#!/usr/bin/env bash
# tests/feature-1145-cleanup-marker.sh
# Tests: hooks/lib/worktree-cleanup-marker.js, hooks/lib/worktree-end-env-anchor.js
# Tags: scope:issue-specific, pwsh-not-required, worktree-end, cleanup-marker
# L1 unit tests for the worktree-cleanup-marker.js CLI (create/delete of <sid>-wt-cleanup-active).
# RED-EXPECTED: hooks/lib/worktree-cleanup-marker.js does not exist yet.
#
# L3 gap (what this test does NOT catch):
# - The marker CLI being invoked at the correct WE steps inside a live claude -p session.
# - Real CLAUDE_SESSION_ID propagation from the worktree-end skill environment.
# Closest-to-action mitigation: hook-registration category checked at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

MARKER_NODE="$_AGENTS_DIR_NODE/hooks/lib/worktree-cleanup-marker.js"
MARKER="$AGENTS_DIR/hooks/lib/worktree-cleanup-marker.js"
ANCHOR_NODE="$_AGENTS_DIR_NODE/hooks/lib/worktree-end-env-anchor.js"
ANCHOR="$AGENTS_DIR/hooks/lib/worktree-end-env-anchor.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'cmkr1'; }

tmp_node_for() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

if [ ! -f "$MARKER" ]; then
    fail "T-marker: hooks/lib/worktree-cleanup-marker.js not present (RED-EXPECTED — not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Helper: check if isWorktreeEndEnv returns true/false for given plans-dir + sid
call_anchor() {
    local plansdir="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$plansdir" run_with_timeout 10 node -e "
const { isWorktreeEndEnv } = require('$ANCHOR_NODE');
console.log(isWorktreeEndEnv('$sid') ? 'true' : 'false');
" 2>/dev/null
}

# --- T-marker-1: create <sid> → marker file exists at <plans-dir>/<sid>-wt-cleanup-active ---
run_t1() {
    local tmp tmp_node sid rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="marker1-sid-$$"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" create "$sid" >/dev/null 2>&1
    rc=$?
    local exists=0
    [ -f "$tmp/${sid}-wt-cleanup-active" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-1: create must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then fail "T-marker-1: marker file must exist after create"; return; fi
    pass "T-marker-1: create <sid> → <plans-dir>/<sid>-wt-cleanup-active exists"
}

# --- T-marker-2: delete <sid> → marker file removed ---
run_t2() {
    local tmp tmp_node sid rc exists
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="marker2-sid-$$"
    touch "$tmp/${sid}-wt-cleanup-active"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" delete "$sid" >/dev/null 2>&1
    rc=$?
    exists=0
    [ -f "$tmp/${sid}-wt-cleanup-active" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-2: delete must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 0 ]; then fail "T-marker-2: marker file must be gone after delete"; return; fi
    pass "T-marker-2: delete <sid> → marker file removed"
}

# --- T-marker-3: delete when marker doesn't exist → exit 0 (fail-safe, no error) ---
run_t3() {
    local tmp tmp_node sid rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="marker3-sid-$$"
    # no file created
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" delete "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-3: delete of absent marker must exit 0 (fail-safe), got rc=$rc"; return; fi
    pass "T-marker-3: delete when marker absent → exit 0 (fail-safe)"
}

# --- T-marker-4: create → isWorktreeEndEnv returns true; delete → returns false ---
run_t4() {
    local tmp tmp_node sid out_after_create out_after_delete rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="marker4-sid-$$"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" create "$sid" >/dev/null 2>&1
    out_after_create=$(call_anchor "$tmp_node" "$sid")

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" delete "$sid" >/dev/null 2>&1
    out_after_delete=$(call_anchor "$tmp_node" "$sid")

    rm -rf "$tmp"

    if [ "$out_after_create" != "true" ]; then
        fail "T-marker-4: after create, isWorktreeEndEnv must return true, got '$out_after_create'"; return; fi
    if [ "$out_after_delete" != "false" ]; then
        fail "T-marker-4: after delete, isWorktreeEndEnv must return false, got '$out_after_delete'"; return; fi
    pass "T-marker-4: create → isWorktreeEndEnv=true; delete → isWorktreeEndEnv=false (integration)"
}

# --- T-marker-5: empty SID → no file created, exit 0 (fail-safe) ---
run_t5() {
    local tmp tmp_node rc file_count
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" create "" >/dev/null 2>&1
    rc=$?
    file_count=$(find "$tmp" -maxdepth 1 -name "*-wt-cleanup-active" | wc -l)
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-5: empty SID create must exit 0 (fail-safe), got rc=$rc"; return; fi
    if [ "$file_count" -ne 0 ]; then fail "T-marker-5: empty SID must not create any marker file, found $file_count"; return; fi
    pass "T-marker-5: empty SID → no marker created, exit 0 (fail-safe)"
}

# --- T-marker-6: unknown command ("bogus") → non-zero exit ---
run_t6() {
    local tmp tmp_node sid rc
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    sid="marker6-sid-$$"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$MARKER_NODE" bogus "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then fail "T-marker-6: unknown command must exit non-zero, got rc=0"; return; fi
    pass "T-marker-6: unknown command 'bogus' → non-zero exit (rc=$rc)"
}

# --- T-marker-7: SID via CLAUDE_SESSION_ID env (no positional arg) → creates file named by env SID ---
run_t7() {
    local tmp tmp_node env_sid rc exists
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    env_sid="marker7-env-sid-$$"
    (
        unset CLAUDE_CODE_SESSION_ID
        WORKFLOW_PLANS_DIR="$tmp_node" CLAUDE_SESSION_ID="$env_sid" \
            run_with_timeout 10 node "$MARKER_NODE" create >/dev/null 2>&1
    )
    rc=$?
    exists=0
    [ -f "$tmp/${env_sid}-wt-cleanup-active" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-7: create via CLAUDE_SESSION_ID must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then
        fail "T-marker-7: marker file must exist named by CLAUDE_SESSION_ID when no positional arg given"; return; fi
    pass "T-marker-7: SID from CLAUDE_SESSION_ID env (no positional arg) → marker created by env SID"
}

# --- T-marker-8 (#2270): SID via CLAUDE_CODE_SESSION_ID env only ---
# A non-native-LLM tool exports only CLAUDE_CODE_SESSION_ID. The marker is the
# worktree-cleanup safety latch, so failing to name it by that SID leaves the
# latch open for exactly the callers that cannot set CLAUDE_SESSION_ID.
# RED until the CLAUDE_CODE_SESSION_ID fallback lands in worktree-cleanup-marker.js.
run_t8() {
    local tmp tmp_node env_sid rc exists
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    env_sid="marker8-env-sid-$$"
    (
        unset CLAUDE_SESSION_ID
        WORKFLOW_PLANS_DIR="$tmp_node" CLAUDE_CODE_SESSION_ID="$env_sid" \
            run_with_timeout 10 node "$MARKER_NODE" create >/dev/null 2>&1
    )
    rc=$?
    exists=0
    [ -f "$tmp/${env_sid}-wt-cleanup-active" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-8: create via CLAUDE_CODE_SESSION_ID must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then
        fail "T-marker-8: marker file must exist named by CLAUDE_CODE_SESSION_ID when no positional arg given"; return; fi
    pass "T-marker-8: SID from CLAUDE_CODE_SESSION_ID env (no positional arg) → marker created by env SID"
}

# --- T-marker-9 (#2270): BOTH env vars set to different ids → which one names the
# marker. The SSOT resolver ranks CLAUDE_CODE_SESSION_ID (Priority 2) above
# CLAUDE_SESSION_ID (Priority 4); the marker must agree, or a session whose two
# variables disagree latches cleanup under an id nobody deletes.
run_t9() {
    local tmp tmp_node cc_sid legacy_sid rc cc_exists legacy_exists
    tmp=$(make_tmp); tmp_node="$(tmp_node_for "$tmp")"
    cc_sid="marker9-cc-sid-$$"
    legacy_sid="marker9-legacy-sid-$$"
    (
        WORKFLOW_PLANS_DIR="$tmp_node" \
        CLAUDE_SESSION_ID="$legacy_sid" \
        CLAUDE_CODE_SESSION_ID="$cc_sid" \
            run_with_timeout 10 node "$MARKER_NODE" create >/dev/null 2>&1
    )
    rc=$?
    cc_exists=0; legacy_exists=0
    [ -f "$tmp/${cc_sid}-wt-cleanup-active" ] && cc_exists=1
    [ -f "$tmp/${legacy_sid}-wt-cleanup-active" ] && legacy_exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-9: create with both env vars must exit 0, got rc=$rc"; return; fi
    if [ $cc_exists -ne 1 ] || [ $legacy_exists -ne 0 ]; then
        fail "T-marker-9: CLAUDE_CODE_SESSION_ID must win (cc_exists=$cc_exists legacy_exists=$legacy_exists)"; return; fi
    pass "T-marker-9: both env vars set → CLAUDE_CODE_SESSION_ID names the marker"
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
