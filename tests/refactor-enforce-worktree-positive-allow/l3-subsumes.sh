
# ============================================================================
# L3 E2E — Subsumes scenarios (cases 31–35)
# ============================================================================

test_l3_31_issue_672_step_e_no_local_git_writes() {
    # #672: step-e.sh under the positive-allow refactor must NOT issue
    # `ISSUE_CLOSE_SKILL=1 git add/commit/push`. Instead it should call the
    # Contents-API helper.
    require_file "$STEP_E_SH" "test_l3_31_issue_672_step_e_no_local_git_writes" || return
    if grep -E '^[^#]*ISSUE_CLOSE_SKILL=1[[:space:]]+git[[:space:]]+(add|commit|push)' "$STEP_E_SH" >/dev/null; then
        fail "L3.31 #672: step-e.sh still issues 'ISSUE_CLOSE_SKILL=1 git add/commit/push' (refactor moves to Contents API)"
    else
        pass "L3.31 #672: step-e.sh no longer issues local ISSUE_CLOSE_SKILL git writes"
    fi
}

test_l3_32_issue_713_issue_create_skill_no_main_worktree_abort() {
    # #713: /issue-create SKILL.md Step 0 main-worktree abort must be REMOVED.
    # After #713, /issue-create is callable from main worktree — no abort guard needed.
    require_file "$ISSUE_CREATE_SKILL" "test_l3_32_issue_713_issue_create_skill_no_main_worktree_abort" || return
    if grep -iE 'Step 0 — Main-worktree pre-flight|must be invoked from a linked worktree' "$ISSUE_CREATE_SKILL" >/dev/null; then
        fail "L3.32 #713: /issue-create SKILL.md still has main-worktree abort guard (Step 0 should be deleted)"
    else
        pass "L3.32 #713: /issue-create SKILL.md main-worktree abort removed"
    fi
}

test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree() {
    require_file "$GUARD_JS" "test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree" || return
    local pair; pair="$(setup_linked_worktree "l3-33")"
    local wt="${pair#*|}"
    local cmd='gh api -X PATCH repos/owner/demo/git/refs/heads/main -f sha=abc'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.33 #527: gh api PATCH git/refs from linked worktree: allowed"
    else
        fail "L3.33 #527: gh api PATCH refs from linked worktree: should allow ($out)"
    fi
}

test_l3_34_issue_419_write_tool_to_workflow_plans() {
    # #419: Write tool to ~/.workflow-plans/ (non-git path) must still be allowed.
    require_file "$GUARD_JS" "test_l3_34_issue_419_write_tool_to_workflow_plans" || return
    local p="$TMPDIR_BASE/workflow-plans-$$"
    mkdir -p "$p"
    local out
    out="$(run_edit_guard "Write" "$p/intent.md" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.34 #419: Write to non-git ~/.workflow-plans path: allowed (fail-open)"
    else
        fail "L3.34 #419: Write to non-git path: should allow ($out)"
    fi
}

test_l3_35_issue_359_stderr_devnull_in_command_subst() {
    # #359: stderr-redirect-to-/dev/null inside command substitution should
    # not be flagged as a write target.
    require_file "$GUARD_JS" "test_l3_35_issue_359_stderr_devnull_in_command_subst" || return
    local pair; pair="$(setup_linked_worktree "l3-35")"
    local wt="${pair#*|}"
    # Inner 2>/dev/null inside a $() — this is a read-classified pattern.
    local cmd='OUT=$(git rev-parse HEAD 2>/dev/null)'
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "L3.35 #359: 2>/dev/null in \$() not flagged as write — allowed"
    else
        fail "L3.35 #359: 2>/dev/null inside cmd subst false-positive ($out)"
    fi
}
