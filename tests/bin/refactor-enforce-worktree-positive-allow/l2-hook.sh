
# ============================================================================
# L2 integration — hook behaviour (cases 24–30)
# ============================================================================

test_l2_24_main_issue_close_skill_add_history_blocked() {
    # Use the EXACT bypassed shape from step-e.sh — two args including the
    # trailing-slash directory. The current bypass matches this verbatim; the
    # refactor must remove that bypass so this command blocks from main.
    require_file "$GUARD_JS" "test_l2_24_main_issue_close_skill_add_history_blocked" || return
    local repo; repo="$(setup_main_checkout "l2-24")"
    local cmd='ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.24 main + ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/: should block (bypass removed)"
    else
        pass "L2.24 main + ISSUE_CLOSE_SKILL=1 git add: bypass removed → blocks"
    fi
}

test_l2_25_linked_worktree_normal_bash_write_allowed() {
    require_file "$GUARD_JS" "test_l2_25_linked_worktree_normal_bash_write_allowed" || return
    local pair; pair="$(setup_linked_worktree "l2-25")"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo body > $wt/notes.txt" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.25 linked worktree + normal bash write: allowed"
    else
        fail "L2.25 linked worktree write: should allow ($out)"
    fi
}

test_l2_26_main_gh_api_put_contents_allowed() {
    # gh api -X PUT contents from main is allowed via gh Group B session-scope.
    require_file "$GUARD_JS" "test_l2_26_main_gh_api_put_contents_allowed" || return
    local repo; repo="$(setup_main_checkout "l2-26")"
    local cmd='gh api -X PUT repos/owner/demo/contents/docs/history.md -f message=msg'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.26 main + gh api -X PUT contents: allow (gh Group B session-scope)"
    else
        fail "L2.26 main + gh api PUT: should allow ($out)"
    fi
}

test_l2_27_non_git_cwd_bash_blocked() {
    require_file "$GUARD_JS" "test_l2_27_non_git_cwd_bash_blocked" || return
    local d="$TMPDIR_BASE/nongit-l2-27-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "echo x > $d/foo" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.27 non-git CWD + Bash write: should block (Change ④)"
    else
        pass "L2.27 non-git CWD + Bash write: blocks (Change ④)"
    fi
}

test_l2_28_non_git_path_write_tool_allowed() {
    require_file "$GUARD_JS" "test_l2_28_non_git_path_write_tool_allowed" || return
    local d="$TMPDIR_BASE/nongit-l2-28-$$"
    mkdir -p "$d"
    local out
    out="$(run_edit_guard "Write" "$d/foo.txt" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.28 non-git path + Write tool: allows"
    else
        fail "L2.28 non-git path + Write tool: should allow ($out)"
    fi
}

test_l2_29_linked_worktree_gh_api_post_blob_allowed() {
    require_file "$GUARD_JS" "test_l2_29_linked_worktree_gh_api_post_blob_allowed" || return
    local pair; pair="$(setup_linked_worktree "l2-29")"
    local wt="${pair#*|}"
    local cmd='gh api -X POST repos/owner/demo/git/blobs -f content=xyz -f encoding=base64'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L2.29 linked worktree + gh api POST git/blobs: allowed"
    else
        fail "L2.29 linked worktree + gh api POST blobs: should allow ($out)"
    fi
}

test_l2_30_main_git_push_origin_main_blocked() {
    require_file "$GUARD_JS" "test_l2_30_main_git_push_origin_main_blocked" || return
    local repo; repo="$(setup_main_checkout "l2-30")"
    local out
    out="$(run_bash_guard "git push origin main" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L2.30 main + git push origin main: should block"
    else
        pass "L2.30 main + git push origin main: blocks"
    fi
}
