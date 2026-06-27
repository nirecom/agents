#!/bin/bash
# tests/fix-923-enforce-worktree-c-flag-main-worktree.sh
# Tests: hooks/enforce-worktree/main-worktree-allows.js
# Tags: enforce-worktree, git-worktree, scope:issue-specific
# RED for issue #923.
# L3 gap (what this test does NOT catch):
# - actual hook invocation from Claude Code Bash tool with real worktree paths
# - Windows path separator handling in live enforce-worktree.js session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

ALLOWS="$AGENTS_DIR/hooks/enforce-worktree/main-worktree-allows.js"
ALLOWS_NODE="$_AGENTS_DIR_NODE/hooks/enforce-worktree/main-worktree-allows.js"

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

# REPO_ROOT is passed as repoRoot arg to isAllowedWorktreeCommand. The path
# is unused for the remove/prune short-circuit but we pass a plausible value.
REPO_ROOT="/some/repo"

call_is_allowed() {
    # Reads cmd from TEST_CMD env var.
    run_with_timeout 5 node -e "
const {isAllowedWorktreeCommand} = require('$ALLOWS_NODE');
const cmd = process.env.TEST_CMD;
process.stdout.write(String(isAllowedWorktreeCommand(cmd, '$REPO_ROOT')));
" 2>/dev/null
    return $?
}

run_t923_1() {
    require_source "$ALLOWS" "T923-1: 'git worktree remove /path/to/wt' -> true" || return
    local out rc
    out=$(TEST_CMD='git worktree remove /path/to/wt' call_is_allowed)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "true" ]; then
        pass "T923-1: 'git worktree remove /path/to/wt' -> true"
    else
        fail "T923-1: 'git worktree remove /path/to/wt' -> true (rc=$rc, out=$out)"
    fi
}

run_t923_2() {
    require_source "$ALLOWS" "T923-2: 'git worktree prune' -> true" || return
    local out rc
    out=$(TEST_CMD='git worktree prune' call_is_allowed)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "true" ]; then
        pass "T923-2: 'git worktree prune' -> true"
    else
        fail "T923-2: 'git worktree prune' -> true (rc=$rc, out=$out)"
    fi
}

# T923-3 (regression): with the -C flag, the predicate must still allow
# `worktree remove`. Before the #923 fix this returned false because the
# subcommand-position regex did not account for `-C <path>` between `git`
# and `worktree`.
run_t923_3() {
    require_source "$ALLOWS" "T923-3: 'git -C /path/to/main worktree remove /wt' -> true" || return
    local out rc
    # repoRoot must match the -C path after the Class 2 fix adds -C validation.
    # call_is_allowed_for passes the matching root so the predicate allows the command.
    out=$(TEST_CMD='git -C /path/to/main worktree remove /path/to/wt' call_is_allowed_for "/path/to/main")
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "true" ]; then
        pass "T923-3: 'git -C /path/to/main worktree remove /wt' -> true"
    else
        fail "T923-3: 'git -C /path/to/main worktree remove /wt' -> true (rc=$rc, out=$out)"
    fi
}

run_t923_4() {
    require_source "$ALLOWS" "T923-4: 'git -C /path/to/main worktree prune' -> true" || return
    local out rc
    # repoRoot must match the -C path after the Class 2 fix adds -C validation.
    out=$(TEST_CMD='git -C /path/to/main worktree prune' call_is_allowed_for "/path/to/main")
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "true" ]; then
        pass "T923-4: 'git -C /path/to/main worktree prune' -> true"
    else
        fail "T923-4: 'git -C /path/to/main worktree prune' -> true (rc=$rc, out=$out)"
    fi
}

# Helper: call isAllowedWorktreeCommand with a custom repoRoot arg.
# Reads cmd from TEST_CMD env var; repoRoot is embedded directly in the node
# script string (same pattern as call_is_allowed/$REPO_ROOT) to avoid Git Bash
# POSIX-to-Windows path conversion that corrupts argv and env-var values when
# passed to Windows executables like node.exe.
call_is_allowed_for() {
    local custom_root="$1"
    run_with_timeout 5 node -e "
const {isAllowedWorktreeCommand} = require('$ALLOWS_NODE');
const cmd = process.env.TEST_CMD;
process.stdout.write(String(isAllowedWorktreeCommand(cmd, '$custom_root')));
" 2>/dev/null
    return $?
}

# T923-5 (pin): -C path matches repoRoot → true (green before and after Class 2 fix)
run_t923_5() {
    require_source "$ALLOWS" "T923-5: 'git -C <repoRoot> worktree remove /wt' with matching repoRoot → true" || return
    local out rc
    out=$(TEST_CMD='git -C /some/repo worktree remove /path/to/wt' call_is_allowed_for "/some/repo")
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "true" ]; then
        pass "T923-5: 'git -C <repoRoot> worktree remove /wt' (matching) → true (pin)"
    else
        fail "T923-5: expected 'true', got '$out' (rc=$rc) — should be green before and after fix"
    fi
}

# T923-6: non-repoRoot -C → false (RED before Class 2 fix — no -C validation yet)
run_t923_6() {
    require_source "$ALLOWS" "T923-6: 'git -C /unrelated worktree remove /wt' → false" || return
    local out rc
    out=$(TEST_CMD='git -C /unrelated/path worktree remove /path/to/wt' call_is_allowed_for "/some/repo")
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "false" ]; then
        pass "T923-6: 'git -C /unrelated/path worktree remove /wt' (non-repoRoot) → false"
    else
        fail "T923-6: expected 'false', got '$out' (rc=$rc) — RED until Class 2 fix"
    fi
}

# T923-7: multiple -C → false (RED before Class 2 fix — no multi-C rejection yet)
run_t923_7() {
    require_source "$ALLOWS" "T923-7: multiple -C flags → false" || return
    local out rc
    out=$(TEST_CMD='git -C /some/repo -C /some/repo worktree remove /path/to/wt' call_is_allowed_for "/some/repo")
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "false" ]; then
        pass "T923-7: 'git -C a -C b worktree remove' (multiple -C) → false"
    else
        fail "T923-7: expected 'false', got '$out' (rc=$rc) — RED until Class 2 fix"
    fi
}

run_t923_1
run_t923_2
run_t923_3
run_t923_4
run_t923_5
run_t923_6
run_t923_7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
