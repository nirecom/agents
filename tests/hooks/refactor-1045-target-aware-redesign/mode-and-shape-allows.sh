#!/bin/bash
# R-12 through R-17: off-mode bypass / linked worktree CWD / git worktree remove /
# git worktree prune / Edit to PLANS_DIR / Edit inside repo
# These cases cover pre-existing allow paths (off-mode, linked worktree, shape-based predicates,
# Edit tool session-scope) that are not gated by require_impl.

# ============================================================================
# R-12: ENFORCE_WORKTREE=off — any command allows (off-mode bypass)
# NOT gated by require_impl — off-mode bypass predates the refactor.
# ============================================================================
test_r12_off_mode_allow() {
    local repo; repo="$(setup_main_checkout "r12")"
    local out
    out="$(run_bash_guard "echo x > \"$repo/foo-r12\"" "$repo" ENFORCE_WORKTREE=off)"
    if guard_decision "$out"; then
        pass "R-12: ENFORCE_WORKTREE=off — write inside repo: allow (off-mode bypass)"
    else
        fail "R-12: ENFORCE_WORKTREE=off — should allow ($out)"
    fi
}

# ============================================================================
# R-13: linked worktree CWD — any write allows (universal rule never reached)
# NOT gated by require_impl — linked worktree allow predates the refactor.
# ============================================================================
test_r13_linked_worktree_allow() {
    local pair; pair="$(setup_linked_worktree "r13")"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo x > $TMPDIR_BASE/foo-r13-$$" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-13: linked worktree CWD → allow (positive-allow, universal rule not reached)"
    else
        fail "R-13: linked worktree CWD: should allow ($out)"
    fi
}

# ============================================================================
# R-14: git worktree remove <path> from main → allow (shape-based predicate)
# NOT gated by require_impl — isAllowedWorktreeCommand exists pre-refactor.
# ============================================================================
test_r14_git_worktree_remove_allow() {
    local pair; pair="$(setup_linked_worktree "r14")"
    local main="${pair%|*}"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "git worktree remove $wt" "$main" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-14: git worktree remove <path> from main → allow (shape-based)"
    else
        fail "R-14: git worktree remove from main: should allow ($out)"
    fi
}

# ============================================================================
# R-15: git worktree prune from main → allow (shape-based predicate)
# NOT gated by require_impl — isAllowedWorktreeCommand exists pre-refactor.
# ============================================================================
test_r15_git_worktree_prune_allow() {
    local repo; repo="$(setup_main_checkout "r15")"
    local out
    out="$(run_bash_guard "git worktree prune" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-15: git worktree prune from main → allow (shape-based)"
    else
        fail "R-15: git worktree prune from main: should allow ($out)"
    fi
}

# ============================================================================
# R-16: Edit tool, file_path=PLANS_DIR/foo.md from main → allow
# isInSessionScope fast-allow for non-git paths (unchanged by refactor).
# NOT gated by require_impl — Edit tool non-git-path fail-open predates refactor.
# ============================================================================
test_r16_edit_plans_dir_allow() {
    local repo; repo="$(setup_main_checkout "r16")"
    local target="$PLANS_DIR_FIXTURE_N/foo.md"
    local out
    out="$(run_edit_guard "Edit" "$target" "$repo" ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$PLANS_DIR_FIXTURE_N")"
    if guard_decision "$out"; then
        pass "R-16: Edit tool to PLANS_DIR path (non-git) from main → allow (isInSessionScope fail-open)"
    else
        fail "R-16: Edit tool to PLANS_DIR: should allow ($out)"
    fi
}

# ============================================================================
# R-17: Edit tool, file_path inside main repo → block (existing behavior)
# NOT gated by require_impl — this is existing main-worktree block behavior.
# ============================================================================
test_r17_edit_inside_repo_block() {
    local repo; repo="$(setup_main_checkout "r17")"
    local out
    out="$(run_edit_guard "Edit" "$repo/docs/history.md" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-17: Edit inside main repo: should block ($out)"
    else
        pass "R-17: Edit inside main repo → block (existing behavior)"
    fi
}

test_r12_off_mode_allow
test_r13_linked_worktree_allow
test_r14_git_worktree_remove_allow
test_r15_git_worktree_prune_allow
test_r16_edit_plans_dir_allow
test_r17_edit_inside_repo_block
