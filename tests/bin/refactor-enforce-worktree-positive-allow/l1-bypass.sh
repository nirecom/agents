
# ============================================================================
# L1 unit — enforce-worktree.js bypass-function removal (cases 1–8)
# ============================================================================

test_l1_1_bypass_functions_not_exported() {
    require_file "$GUARD_JS" "test_l1_1_bypass_functions_not_exported" || return
    local fns=(
        isAllowedHistoryWriteViaIssueCloseSkill
        isAllowedHistoryPushViaIssueCloseSkill
        isAllowedHistoryWriteViaComposeDocAppendSkill
        isAllowedHistoryPushViaComposeDocAppendSkill
    )
    local all_removed=1
    for fn in "${fns[@]}"; do
        local kind; kind="$(get_export_kind "$fn")"
        if [ "$kind" = "function" ]; then
            fail "L1.1 bypass function $fn still exported (refactor removes it)"
            all_removed=0
        fi
    done
    [ "$all_removed" = "1" ] && pass "L1.1 all 4 bypass functions removed from module.exports"
}

test_l1_2_issue_close_skill_inline_blocked_in_main() {
    require_file "$GUARD_JS" "test_l1_2_issue_close_skill_inline_blocked_in_main" || return
    local repo; repo="$(setup_main_checkout "l1-2-main")"
    local cmd='ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.2 ISSUE_CLOSE_SKILL=1 git add from main: should block (no bypass)"
    else
        pass "L1.2 ISSUE_CLOSE_SKILL=1 git add from main: blocks (no bypass)"
    fi
}

test_l1_3_compose_doc_append_skill_inline_blocked_in_main() {
    require_file "$GUARD_JS" "test_l1_3_compose_doc_append_skill_inline_blocked_in_main" || return
    local repo; repo="$(setup_main_checkout "l1-3-main")"
    local cmd='COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.3 COMPOSE_DOC_APPEND_SKILL=1 git add from main: should block"
    else
        pass "L1.3 COMPOSE_DOC_APPEND_SKILL=1 git add from main: blocks"
    fi
}

test_l1_3b_compose_doc_append_no_prefix_via_bash_allowed_from_main() {
    require_file "$GUARD_JS" "test_l1_3b_compose_doc_append_no_prefix_via_bash_allowed_from_main" || return
    local repo; repo="$(setup_main_checkout "l1-3b-main")"
    local bin; bin="${_AGENTS_DIR_NODE}/bin/compose-doc-append-entry"
    local cmd; cmd="bash \"$bin\" --notes /dev/null --branch x --pr 1 --merge-commit abc --background x --closes-issues-count 0"
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.3b bash compose-doc-append-entry (no prefix) from main: allows"
    else
        fail "L1.3b bash compose-doc-append-entry (no prefix) from main: should allow (bash-script form is read)"
    fi
}

test_l1_4_bash_in_non_git_cwd_blocks() {
    # Change ④: Bash write command in a non-git CWD is now BLOCK, not allow.
    # The previous fail-open allowed echo/cp/mv outside any repo, which masked
    # mis-targeted writes. The Edit/Write fail-open remains (test L1.5).
    require_file "$GUARD_JS" "test_l1_4_bash_in_non_git_cwd_blocks" || return
    local d="$TMPDIR_BASE/nongit-bash-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "echo x > $d/foo" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.4 Bash write in non-git CWD: should BLOCK (Change ④)"
    else
        pass "L1.4 Bash write in non-git CWD: blocks (Change ④)"
    fi
}

test_l1_5_edit_to_non_git_path_allows() {
    # The Edit/Write fail-open for non-git paths remains. Only Bash flips.
    require_file "$GUARD_JS" "test_l1_5_edit_to_non_git_path_allows" || return
    local d="$TMPDIR_BASE/nongit-edit-$$"
    mkdir -p "$d"
    local out
    out="$(run_edit_guard "Write" "$d/foo.txt" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.5 Write tool to non-git path: allows (fail-open maintained)"
    else
        fail "L1.5 Write tool to non-git path: should allow (Edit fail-open) ($out)"
    fi
}

test_l1_6_linked_worktree_feature_branch_allows() {
    require_file "$GUARD_JS" "test_l1_6_linked_worktree_feature_branch_allows" || return
    local pair; pair="$(setup_linked_worktree "l1-6")"
    local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.6 linked worktree + feature branch: allows (positive-allow)"
    else
        fail "L1.6 linked worktree + feature branch: should allow ($out)"
    fi
}

test_l1_7_main_worktree_denies() {
    require_file "$GUARD_JS" "test_l1_7_main_worktree_denies" || return
    local repo; repo="$(setup_main_checkout "l1-7")"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "L1.7 main worktree write: should deny ($out)"
    else
        pass "L1.7 main worktree write: denies"
    fi
}

test_l1_8_existing_lifecycle_exceptions_intact() {
    require_file "$GUARD_JS" "test_l1_8_existing_lifecycle_exceptions_intact" || return

    # isAllowedFastForwardMerge still works (main + git merge --ff-only).
    local repo; repo="$(setup_main_checkout "l1-8-ff")"
    local out
    out="$(run_bash_guard "git merge --ff-only origin/feature" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.8a isAllowedFastForwardMerge: still allows from main"
    else
        fail "L1.8a fast-forward merge: should allow from main ($out)"
    fi

    # isAllowedWorktreeCommand still works (git worktree list).
    local pair; pair="$(setup_linked_worktree "l1-8-wt")"
    local main="${pair%|*}"
    out="$(run_bash_guard "git worktree list --porcelain" "$main" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L1.8b isAllowedWorktreeCommand: still allows from main"
    else
        fail "L1.8b git worktree list: should allow from main ($out)"
    fi
}
