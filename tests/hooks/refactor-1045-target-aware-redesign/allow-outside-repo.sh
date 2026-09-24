#!/bin/bash
# R-1 through R-7: redirect/tee/cp/New-Item outside repo + PLANS_DIR-outside-repo + rm outside repo
# All cases assert that universal-target-allow.js allows writes with every target outside the repo.

# ============================================================================
# R-1: redirect to /tmp (outside repo) from main → allow
# ============================================================================
test_r1_redirect_outside_repo_allow() {
    require_impl "R-1" || return
    local repo; repo="$(setup_main_checkout "r1")"
    local target="$TMPDIR_BASE/foo-r1-$$"
    local out
    out="$(run_bash_guard "echo x > $target" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-1: redirect target outside repo from main → allow"
    else
        fail "R-1: redirect target outside repo from main: should allow ($out)"
    fi
}

# ============================================================================
# R-2: tee to /tmp (outside repo) from main → allow
# ============================================================================
test_r2_tee_outside_repo_allow() {
    require_impl "R-2" || return
    local repo; repo="$(setup_main_checkout "r2")"
    local target="$TMPDIR_BASE/foo-r2-$$"
    local out
    out="$(run_bash_guard "echo x | tee $target" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-2: tee target outside repo from main → allow"
    else
        fail "R-2: tee target outside repo from main: should allow ($out)"
    fi
}

# ============================================================================
# R-3: cp with destination outside repo from main → allow
# ============================================================================
test_r3_cp_outside_repo_allow() {
    require_impl "R-3" || return
    local repo; repo="$(setup_main_checkout "r3")"
    local src="$TMPDIR_BASE/src-r3-$$"
    local dst="$TMPDIR_BASE/dst-r3-$$"
    touch "$src" 2>/dev/null || true
    local out
    out="$(run_bash_guard "cp $src $dst" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-3: cp destination outside repo from main → allow"
    else
        fail "R-3: cp destination outside repo from main: should allow ($out)"
    fi
}

# ============================================================================
# R-4: New-Item -ItemType Directory with -Path outside repo → allow
# ============================================================================
test_r4_new_item_outside_repo_allow() {
    require_impl "R-4" || return
    local repo; repo="$(setup_main_checkout "r4")"
    local target="$TMPDIR_BASE/newdir-r4-$$"
    local out
    out="$(run_bash_guard "New-Item -ItemType Directory -Path \"$target\"" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-4: New-Item -ItemType Directory outside repo → allow"
    else
        fail "R-4: New-Item -ItemType Directory outside repo: should allow ($out)"
    fi
}

# ============================================================================
# R-5: redirect to PLANS_DIR outside repo → allow (semantic carry from #957 A6)
# ============================================================================
test_r5_plans_dir_redirect_outside_repo_allow() {
    require_impl "R-5" || return
    local repo; repo="$(setup_main_checkout "r5")"
    local target="$PLANS_DIR_FIXTURE_N/sess/foo.md"
    local out
    out="$(run_bash_guard "echo x > \"$target\"" "$repo" ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$PLANS_DIR_FIXTURE_N")"
    if guard_decision "$out"; then
        pass "R-5: redirect to PLANS_DIR-outside-repo from main → allow"
    else
        fail "R-5: redirect to PLANS_DIR-outside-repo: should allow ($out)"
    fi
}

# ============================================================================
# R-6: tee to PLANS_DIR outside repo → allow
# ============================================================================
test_r6_plans_dir_tee_outside_repo_allow() {
    require_impl "R-6" || return
    local repo; repo="$(setup_main_checkout "r6")"
    local target="$PLANS_DIR_FIXTURE_N/sess/bar.md"
    local out
    out="$(run_bash_guard "echo x | tee \"$target\"" "$repo" ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$PLANS_DIR_FIXTURE_N")"
    if guard_decision "$out"; then
        pass "R-6: tee to PLANS_DIR-outside-repo from main → allow"
    else
        fail "R-6: tee to PLANS_DIR-outside-repo: should allow ($out)"
    fi
}

# ============================================================================
# R-7: rm of a file outside repo from main → allow
# ============================================================================
test_r7_rm_outside_repo_allow() {
    require_impl "R-7" || return
    local repo; repo="$(setup_main_checkout "r7")"
    local target="$TMPDIR_BASE/some-file-r7-$$"
    touch "$target" 2>/dev/null || true
    local out
    out="$(run_bash_guard "rm $target" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-7: rm outside repo from main → allow"
    else
        fail "R-7: rm outside repo from main: should allow ($out)"
    fi
}

test_r1_redirect_outside_repo_allow
test_r2_tee_outside_repo_allow
test_r3_cp_outside_repo_allow
test_r4_new_item_outside_repo_allow
test_r5_plans_dir_redirect_outside_repo_allow
test_r6_plans_dir_tee_outside_repo_allow
test_r7_rm_outside_repo_allow
